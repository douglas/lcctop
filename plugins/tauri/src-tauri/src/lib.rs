use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use tauri::{AppHandle, Emitter};

// ── Session data model ─────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TerminalInfo {
    pub program: String,
    pub tty: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Subagent {
    pub agent_id: String,
    pub agent_type: String,
    pub started_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    pub session_id: String,
    pub project_path: String,
    pub project_name: String,
    pub branch: String,
    pub status: String,
    pub last_prompt: Option<String>,
    pub last_activity: String,
    pub started_at: String,
    pub terminal: Option<TerminalInfo>,
    pub pid: u32,
    pub pid_start_time: Option<f64>,
    pub last_tool: Option<String>,
    pub last_tool_detail: Option<String>,
    pub notification_message: Option<String>,
    pub session_name: Option<String>,
    pub workspace_file: Option<String>,
    pub source: Option<String>,
    pub ended_at: Option<String>,
    #[serde(default)]
    pub active_subagents: Vec<Subagent>,
}

// ── Status priority for sorting ────────────────────────────────────────────

fn status_priority(status: &str) -> u8 {
    match status {
        "waiting_permission" => 0,
        "waiting_input" | "needs_attention" => 1,
        "working" | "compacting" => 2,
        "idle" => 3,
        _ => 4,
    }
}

// ── Process liveness ────────────────────────────────────────────────────────

/// Returns true if the process is alive (not a zombie).
/// Reads /proc/{pid}/stat and checks the state field (index 2 after "(comm)").
fn is_process_alive(pid: u32) -> bool {
    let stat_path = format!("/proc/{}/stat", pid);
    match fs::read_to_string(&stat_path) {
        Err(_) => false, // File missing = process gone
        Ok(contents) => {
            // /proc/{pid}/stat format: pid (comm) state ...
            // The comm field may contain spaces and parentheses, so we find the last ')'
            // and parse fields after it.
            if let Some(close_paren) = contents.rfind(')') {
                let after_comm = contents[close_paren + 1..].trim_start();
                let state = after_comm.chars().next().unwrap_or('Z');
                state != 'Z'
            } else {
                false
            }
        }
    }
}

// ── /proc stat field parsing ────────────────────────────────────────────────

/// Parses /proc/{pid}/stat, returning a struct with the fields we need.
#[derive(Default)]
struct ProcStat {
    ppid: u32,
    tty_nr: i32,
    starttime: u64,
}

fn parse_proc_stat(pid: u32) -> Option<ProcStat> {
    let contents = fs::read_to_string(format!("/proc/{}/stat", pid)).ok()?;
    // Find the comm field: everything between first '(' and last ')'
    let close = contents.rfind(')')?;

    let rest = &contents[close + 1..];
    let fields: Vec<&str> = rest.split_whitespace().collect();
    // After ')': state ppid pgrp session tty_nr ...
    // indices (0-based from rest):
    //   0 = state
    //   1 = ppid
    //   2 = pgrp
    //   3 = session
    //   4 = tty_nr
    //  19 = starttime
    let ppid: u32 = fields.get(1)?.parse().ok()?;
    let tty_nr: i32 = fields.get(4)?.parse().ok()?;
    let starttime: u64 = fields.get(19)?.parse().ok()?;

    Some(ProcStat { ppid, tty_nr, starttime })
}

/// Read the process name from /proc/{pid}/comm
fn read_comm(pid: u32) -> Option<String> {
    fs::read_to_string(format!("/proc/{}/comm", pid))
        .ok()
        .map(|s| s.trim().to_lowercase())
}

// ── PPID chain walking ──────────────────────────────────────────────────────

/// Walk up the process tree from `start_pid` until we find a known terminal.
/// Returns (terminal_name, terminal_pid, tab_root_pid)
/// tab_root is the direct child of the terminal that is an ancestor of start_pid.
fn find_terminal_ancestor(start_pid: u32) -> Option<(String, u32, u32)> {
    let terminals = ["ghostty", "kitty", "alacritty", "wezterm", "foot"];
    let mut current = start_pid;

    for _ in 0..32 {
        let stat = parse_proc_stat(current)?;
        if stat.ppid == 0 || stat.ppid == 1 {
            break;
        }
        let parent_comm = read_comm(stat.ppid)?;
        let parent_comm_lower = parent_comm.to_lowercase();

        for &term in &terminals {
            if parent_comm_lower.contains(term) {
                // `current` is the direct child of the terminal (the tab root)
                return Some((term.to_string(), stat.ppid, current));
            }
        }

        current = stat.ppid;
    }
    None
}

// ── Ghostty tab focusing ────────────────────────────────────────────────────

/// Count how many Hyprland windows share the given PID (ghostty single-process model
/// means all windows report the same PID in `hyprctl clients -j`).
fn count_windows_for_pid(pid: u32) -> usize {
    let output = match Command::new("hyprctl").args(["clients", "-j"]).output() {
        Ok(o) => o,
        Err(_) => return 1,
    };
    let json_str = String::from_utf8_lossy(&output.stdout);
    let clients: serde_json::Value = match serde_json::from_str(&json_str) {
        Ok(v) => v,
        Err(_) => return 1,
    };
    clients
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter(|c| {
                    c.get("pid")
                        .and_then(|v| v.as_u64())
                        .map(|p| p == pid as u64)
                        .unwrap_or(false)
                })
                .count()
        })
        .unwrap_or(1)
}

/// Find the 1-based tab index for `tab_root` among ghostty's direct children
/// that have a controlling TTY, sorted by starttime ascending.
///
/// `window_count` is the number of Hyprland windows sharing `ghostty_pid`.
/// When >1, Alt+N is ambiguous (it's per-window, not global), so we return None
/// to skip tab switching and rely on window focus alone.
fn ghostty_tab_index(ghostty_pid: u32, tab_root_pid: u32, window_count: usize) -> Option<usize> {
    if window_count > 1 {
        return None;
    }
    // Enumerate /proc/*/stat to find direct children of ghostty_pid with tty_nr != 0
    let proc_dir = Path::new("/proc");
    let entries = fs::read_dir(proc_dir).ok()?;

    let mut children: Vec<(u64, u32)> = Vec::new(); // (starttime, pid)

    for entry in entries.flatten() {
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        let child_pid: u32 = match name_str.parse() {
            Ok(n) => n,
            Err(_) => continue,
        };

        if let Some(stat) = parse_proc_stat(child_pid) {
            if stat.ppid == ghostty_pid && stat.tty_nr != 0 {
                children.push((stat.starttime, child_pid));
            }
        }
    }

    if children.is_empty() {
        return None;
    }

    // Sort by starttime ascending (oldest tab = tab 1)
    children.sort_by_key(|(st, _)| *st);

    // Find 1-based position of tab_root
    children
        .iter()
        .position(|(_, pid)| *pid == tab_root_pid)
        .map(|i| i + 1)
}

// ── Kitty tab focusing ──────────────────────────────────────────────────────

/// Parse `kitty @ ls` JSON output to find the tab containing `target_pid`.
/// Returns the tab id.
fn kitty_find_tab(target_pid: u32) -> Option<u64> {
    let output = Command::new("kitty")
        .args(["@", "ls"])
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let json_str = String::from_utf8_lossy(&output.stdout);
    // Structure: [ { "tabs": [ { "id": N, "windows": [ { "pid": N, ... } ] } ] } ]
    // We use a simple JSON walk rather than adding a dep on serde_json Value parsing
    // (serde_json is already in deps)
    let parsed: serde_json::Value = serde_json::from_str(&json_str).ok()?;

    let os_windows = parsed.as_array()?;
    for os_win in os_windows {
        let tabs = os_win.get("tabs")?.as_array()?;
        for tab in tabs {
            let tab_id = tab.get("id")?.as_u64()?;
            let windows = tab.get("windows")?.as_array()?;
            for window in windows {
                if let Some(pid_val) = window.get("pid").and_then(|v| v.as_u64()) {
                    if pid_val == target_pid as u64 {
                        return Some(tab_id);
                    }
                    // Also check foreground_processes
                    if let Some(procs) = window
                        .get("foreground_processes")
                        .and_then(|v| v.as_array())
                    {
                        for proc in procs {
                            if proc
                                .get("pid")
                                .and_then(|v| v.as_u64())
                                .map(|p| p == target_pid as u64)
                                .unwrap_or(false)
                            {
                                return Some(tab_id);
                            }
                        }
                    }
                }
            }
        }
    }
    None
}

// ── hyprctl window focus ────────────────────────────────────────────────────

/// When multiple Ghostty windows share one PID, use the tab_root_pid (direct
/// child of ghostty that is an ancestor of the session process) to identify
/// the correct Hyprland window address.
///
/// Strategy: sort ghostty's tty-owning children by starttime (oldest = window 1)
/// and sort addresses by stableId (lowest = window 1). Both increase monotonically
/// with window creation order, so the i-th tab root maps to the i-th address.
fn ghostty_resolve_address(ghostty_pid: u32, tab_root_pid: u32, addresses: &[(String, u64)]) -> Option<String> {
    if tab_root_pid == 0 {
        return addresses.first().map(|(a, _)| a.clone());
    }

    let proc_dir = Path::new("/proc");
    let proc_entries = match fs::read_dir(proc_dir) {
        Ok(e) => e,
        Err(_) => return addresses.first().map(|(a, _)| a.clone()),
    };

    let mut tab_roots: Vec<(u64, u32)> = Vec::new(); // (starttime, pid)

    for entry in proc_entries.flatten() {
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        let child_pid: u32 = match name_str.parse() {
            Ok(n) => n,
            Err(_) => continue,
        };

        if let Some(stat) = parse_proc_stat(child_pid) {
            if stat.ppid == ghostty_pid && stat.tty_nr != 0 {
                tab_roots.push((stat.starttime, child_pid));
            }
        }
    }

    if tab_roots.is_empty() {
        return addresses.first().map(|(a, _)| a.clone());
    }

    tab_roots.sort_by_key(|(st, _)| *st);

    // 1:1 mapping only when counts match (one tab per window)
    if tab_roots.len() != addresses.len() {
        return addresses.first().map(|(a, _)| a.clone());
    }

    // Find position of our tab root in the starttime-ordered list
    if let Some(idx) = tab_roots.iter().position(|(_, pid)| *pid == tab_root_pid) {
        addresses.get(idx).map(|(a, _)| a.clone())
    } else {
        addresses.first().map(|(a, _)| a.clone())
    }
}

/// Walk up the ppid chain from start_pid and find the window address in hyprctl clients.
/// When multiple addresses share a PID (ghostty multi-window), use tab_root_pid
/// (direct child of ghostty that is ancestor of start_pid) for correlation.
fn hyprctl_focus(start_pid: u32, tab_root_pid: Option<u32>) -> bool {
    let output = match Command::new("hyprctl").args(["clients", "-j"]).output() {
        Ok(o) => o,
        Err(_) => return false,
    };

    let json_str = String::from_utf8_lossy(&output.stdout);
    let clients: serde_json::Value = match serde_json::from_str(&json_str) {
        Ok(v) => v,
        Err(_) => return false,
    };

    let clients_arr = match clients.as_array() {
        Some(a) => a,
        None => return false,
    };

    // Build a map of pid → [(address, stableId)] from all hyprctl clients.
    // stableId is a hex string (e.g. "1800017d") — parse as base 16.
    let mut pid_to_addresses: std::collections::HashMap<u32, Vec<(String, u64)>> =
        std::collections::HashMap::new();
    for client in clients_arr {
        if let (Some(client_pid), Some(address)) = (
            client.get("pid").and_then(|v| v.as_u64()),
            client.get("address").and_then(|v| v.as_str()),
        ) {
            let stable_id = client
                .get("stableId")
                .and_then(|v| v.as_str())
                .and_then(|s| u64::from_str_radix(s, 16).ok())
                .unwrap_or(0);
            pid_to_addresses
                .entry(client_pid as u32)
                .or_default()
                .push((address.to_string(), stable_id));
        }
    }
    // Sort each entry by stable_id ascending
    for entries in pid_to_addresses.values_mut() {
        entries.sort_by_key(|(_, sid)| *sid);
    }

    // Walk up the ancestor chain; return on the FIRST (closest) pid that is a known window
    let mut pid = start_pid;
    for _ in 0..32 {
        if let Some(entries) = pid_to_addresses.get(&pid) {
            let address = if entries.len() == 1 {
                entries[0].0.clone()
            } else {
                ghostty_resolve_address(pid, tab_root_pid.unwrap_or(0), entries)
                    .unwrap_or_else(|| entries[0].0.clone())
            };
            let _ = Command::new("hyprctl")
                .args(["dispatch", "focuswindow", &format!("address:{}", address)])
                .status();
            return true;
        }
        match parse_proc_stat(pid) {
            Some(s) if s.ppid > 1 => pid = s.ppid,
            _ => break,
        }
    }
    false
}

// ── Tauri commands ──────────────────────────────────────────────────────────

mod commands {
    use super::*;

#[tauri::command]
pub fn list_sessions() -> Vec<Session> {
    let home = match std::env::var("HOME") {
        Ok(h) => h,
        Err(_) => return vec![],
    };

    let sessions_dir = PathBuf::from(&home).join(".cctop").join("sessions");

    let entries = match fs::read_dir(&sessions_dir) {
        Ok(e) => e,
        Err(_) => return vec![],
    };

    let mut sessions: Vec<Session> = Vec::new();

    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }

        let contents = match fs::read_to_string(&path) {
            Ok(c) => c,
            Err(_) => continue,
        };

        let session: Session = match serde_json::from_str(&contents) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("lcctop-tauri: failed to parse {:?}: {}", path, e);
                continue;
            }
        };

        // Filter out dead/zombie processes
        if !is_process_alive(session.pid) {
            continue;
        }

        sessions.push(session);
    }

    // Sort: status priority first, then last_activity descending
    sessions.sort_by(|a, b| {
        let pa = status_priority(&a.status);
        let pb = status_priority(&b.status);
        if pa != pb {
            return pa.cmp(&pb);
        }
        // Descending by last_activity (ISO8601 strings sort lexicographically)
        b.last_activity.cmp(&a.last_activity)
    });

    sessions
}

#[tauri::command]
pub fn focus_session(pid: u32) {
    // Find terminal ancestor first so tab_root_pid is available for window resolution
    let terminal_info = find_terminal_ancestor(pid);
    let tab_root_pid = terminal_info.as_ref().map(|(_, _, tr)| *tr);

    // Step 1: Focus the correct window via hyprctl
    hyprctl_focus(pid, tab_root_pid);

    // Step 2: Wait for Wayland focus to settle before sending keystrokes
    std::thread::sleep(std::time::Duration::from_millis(50));

    // Step 3: Handle tab switching using the already-computed terminal info
    if let Some((terminal_name, terminal_pid, tab_root_pid)) = terminal_info {
        match terminal_name.as_str() {
            "ghostty" => {
                let window_count = count_windows_for_pid(terminal_pid);
                if let Some(tab_index) = ghostty_tab_index(terminal_pid, tab_root_pid, window_count) {
                    // Use wtype to send Alt+N (1-based tab index)
                    let key = tab_index.to_string();
                    let _ = Command::new("wtype")
                        .args(["-M", "alt", "-k", &key])
                        .status();
                }
            }

            "kitty" => {
                // Search from the session pid downward (or use the pid directly)
                if let Some(tab_id) = kitty_find_tab(pid) {
                    let tab_id_str = tab_id.to_string();
                    let _ = Command::new("kitty")
                        .args(["@", "focus-tab", "--match", &format!("id:{}", tab_id_str)])
                        .status();
                }
            }

            _ => {
                // No tab support (alacritty, wezterm, foot, etc.); window focus is sufficient
            }
        }
    }
}

#[tauri::command]
pub fn hide_window(window: tauri::Window) {
    window.hide().ok();
}

} // mod commands

// ── File watcher ────────────────────────────────────────────────────────────

fn sessions_dir() -> Option<PathBuf> {
    let home = std::env::var("HOME").ok()?;
    Some(PathBuf::from(home).join(".cctop").join("sessions"))
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .setup(|app| {
            let app_handle = app.handle().clone();
            let sessions_path = sessions_dir();

            if let Some(path) = sessions_path {
                // Ensure sessions directory exists
                let _ = fs::create_dir_all(&path);

                // Spawn a thread for the file watcher
                std::thread::spawn(move || {
                    watch_sessions_dir(path, app_handle);
                });
            }

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::list_sessions,
            commands::focus_session,
            commands::hide_window,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

fn watch_sessions_dir(path: PathBuf, app_handle: AppHandle) {
    use notify::{Config, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
    use std::sync::mpsc::channel;
    use std::time::Duration;

    let (tx, rx) = channel();

    let mut watcher = match RecommendedWatcher::new(
        move |res| {
            if let Ok(event) = res {
                let _ = tx.send(event);
            }
        },
        Config::default().with_poll_interval(Duration::from_millis(500)),
    ) {
        Ok(w) => w,
        Err(e) => {
            eprintln!("lcctop-tauri: failed to create watcher: {}", e);
            return;
        }
    };

    if let Err(e) = watcher.watch(&path, RecursiveMode::NonRecursive) {
        eprintln!("lcctop-tauri: failed to watch {:?}: {}", path, e);
        return;
    }

    // Debounce: emit at most once per 200ms burst of changes
    let debounce = Duration::from_millis(200);

    while let Ok(event) = rx.recv() {
        // Only care about create/modify/remove events
        let relevant = matches!(
            event.kind,
            EventKind::Create(_) | EventKind::Modify(_) | EventKind::Remove(_)
        );
        if !relevant {
            continue;
        }

        // Drain any queued events within the debounce window
        let _ = rx.recv_timeout(debounce);
        while rx.try_recv().is_ok() {}

        // Emit to all windows
        if let Err(e) = app_handle.emit("sessions-changed", ()) {
            eprintln!("lcctop-tauri: failed to emit event: {}", e);
        }
    }
}
