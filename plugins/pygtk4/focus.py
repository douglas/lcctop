"""
Focus logic: port of plugins/ags/lib/focus.ts.
Finds the correct Hyprland window for a session and switches to the right terminal tab.
"""

import glob
import json
import os
import subprocess


# ---------------------------------------------------------------------------
# /proc helpers
# ---------------------------------------------------------------------------

def read_proc_stat(pid: int) -> dict | None:
    """
    Parse /proc/{pid}/stat.
    Returns dict with pid, comm, state, ppid, tty_nr, starttime — or None.
    """
    try:
        with open(f"/proc/{pid}/stat") as f:
            text = f.read()
        paren_open  = text.index("(")
        paren_close = text.rindex(")")
        comm = text[paren_open + 1:paren_close]
        rest = text[paren_close + 2:].split()
        # rest[0]=state, rest[1]=ppid, rest[4]=tty_nr, rest[19]=starttime
        return {
            "pid":       pid,
            "comm":      comm,
            "state":     rest[0],
            "ppid":      int(rest[1]),
            "tty_nr":    int(rest[4]),
            "starttime": int(rest[19]),
        }
    except Exception:
        return None


def read_comm(pid: int) -> str | None:
    try:
        with open(f"/proc/{pid}/comm") as f:
            return f.read().strip()
    except Exception:
        return None


def ppid_chain(pid: int) -> list[int]:
    """Walk /proc ppid chain upward. Returns list of PIDs, child first."""
    chain:   list[int] = []
    current: int       = pid
    visited: set[int]  = set()

    while current > 1 and current not in visited:
        visited.add(current)
        chain.append(current)
        stat = read_proc_stat(current)
        if not stat:
            break
        current = stat["ppid"]

    return chain


# ---------------------------------------------------------------------------
# Terminal detection
# ---------------------------------------------------------------------------

def detect_terminal_type(pid: int) -> tuple[str, int]:
    """Returns (type, term_pid). type is 'ghostty'|'kitty'|'alacritty'|'unknown'."""
    chain = ppid_chain(pid)
    for p in chain:
        comm = read_comm(p)
        if not comm:
            continue
        c = comm.lower()
        if "ghostty"   in c: return ("ghostty",   p)
        if "kitty"     in c: return ("kitty",     p)
        if "alacritty" in c: return ("alacritty", p)
    return ("unknown", 0)


# ---------------------------------------------------------------------------
# Hyprland: find window address
# ---------------------------------------------------------------------------

def hyprctl_clients() -> list[dict]:
    """Returns list of {pid, address, stable_id} dicts."""
    try:
        result = subprocess.run(
            ["hyprctl", "clients", "-j"],
            capture_output=True, text=True, timeout=2,
        )
        if result.returncode != 0:
            return []
        raw = json.loads(result.stdout)
        clients = []
        for c in raw:
            sid_str = c.get("stableId") or c.get("stable_id") or "0"
            try:
                stable_id = int(str(sid_str), 16)
            except ValueError:
                stable_id = 0
            clients.append({
                "pid":       c["pid"],
                "address":   c["address"],
                "stable_id": stable_id,
            })
        return clients
    except Exception:
        return []


def find_tab_root(session_pid: int, term_pid: int) -> int | None:
    """Walk from session_pid up to term_pid; return the direct child of term_pid."""
    pid = session_pid
    for _ in range(8):
        stat = read_proc_stat(pid)
        if not stat:
            break
        if stat["ppid"] == term_pid:
            return pid
        if stat["ppid"] <= 1:
            break
        pid = stat["ppid"]
    return None


def enum_tab_roots(term_pid: int) -> list[dict]:
    """
    Enumerate direct children of term_pid that have a controlling TTY,
    sorted by starttime ascending (oldest = window 1).
    Returns list of {pid, starttime} dicts.
    """
    tab_roots: list[dict] = []
    for path in glob.glob("/proc/[0-9]*/stat"):
        try:
            child_pid = int(os.path.basename(os.path.dirname(path)))
        except ValueError:
            continue
        stat = read_proc_stat(child_pid)
        if not stat:
            continue
        if stat["ppid"] != term_pid:
            continue
        if stat["tty_nr"] == 0:
            continue
        tab_roots.append({"pid": child_pid, "starttime": stat["starttime"]})

    tab_roots.sort(key=lambda t: t["starttime"])
    return tab_roots


def ghostty_resolve_address(
    term_pid:     int,
    tab_root_pid: int | None,
    entries:      list[dict],
) -> str:
    """
    When multiple ghostty windows share one PID, resolve the correct address.
    stableId (entries) and starttime (tab roots) both increase monotonically
    with window creation order — so the i-th tab root maps to the i-th entry.
    """
    if not tab_root_pid:
        return entries[0]["address"]

    tab_roots = enum_tab_roots(term_pid)
    if not tab_roots:
        return entries[0]["address"]

    idx = next((i for i, t in enumerate(tab_roots) if t["pid"] == tab_root_pid), -1)
    if idx == -1 or idx >= len(entries):
        return entries[0]["address"]

    return entries[idx]["address"]


def find_hypr_window_address(session_pid: int, clients: list[dict]) -> str | None:
    if not clients:
        return None

    chain = ppid_chain(session_pid)
    for p in chain:
        matching = [c for c in clients if c["pid"] == p]
        if not matching:
            continue
        if len(matching) == 1:
            return matching[0]["address"]
        # Multiple windows share this PID (ghostty multi-window):
        # sort by stable_id ascending (creation order), then use tab root to pick.
        matching.sort(key=lambda c: c["stable_id"])
        tab_root = find_tab_root(session_pid, p)
        return ghostty_resolve_address(p, tab_root, matching)

    return None


# ---------------------------------------------------------------------------
# Ghostty tab switch
# ---------------------------------------------------------------------------

def ghostty_tab_switch(term_pid: int, session_pid: int, clients: list[dict]) -> None:
    """
    Send Alt+N to switch to the correct tab within the focused ghostty window.
    Skipped when multiple windows share the ghostty PID (Alt+N is per-window,
    so a global tab index is ambiguous across windows).
    """
    window_count = sum(1 for c in clients if c["pid"] == term_pid)
    if window_count > 1:
        return

    tab_children = enum_tab_roots(term_pid)
    if not tab_children:
        return

    chain_set = set(ppid_chain(session_pid))
    tab_index = -1
    for i, tab in enumerate(tab_children):
        if tab["pid"] in chain_set:
            tab_index = i + 1  # 1-based
            break

    if tab_index == -1 or tab_index > 8:
        return

    subprocess.Popen(["wtype", "-M", "alt", "-k", str(tab_index)])


# ---------------------------------------------------------------------------
# Kitty tab switch
# ---------------------------------------------------------------------------

def kitty_tab_switch(session_pid: int) -> None:
    try:
        result = subprocess.run(
            ["kitty", "@", "ls"],
            capture_output=True, text=True, timeout=2,
        )
        if result.returncode != 0:
            return
        os_windows = json.loads(result.stdout)
        for os_win in os_windows:
            for tab in os_win.get("tabs", []):
                for win in tab.get("windows", []):
                    if win.get("pid") == session_pid:
                        subprocess.Popen(
                            ["kitty", "@", "focus-tab", f"--match=id:{tab['id']}"]
                        )
                        return
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

def focus_session(session: dict) -> None:
    """Focus the Hyprland window for a session, then switch to the correct tab."""
    pid     = session.get("pid")
    clients = hyprctl_clients()

    address = find_hypr_window_address(pid, clients)
    if address:
        subprocess.Popen(["hyprctl", "dispatch", "focuswindow", f"address:{address}"])

    term_type, term_pid = detect_terminal_type(pid)

    if term_type == "ghostty":
        ghostty_tab_switch(term_pid, pid, clients)
    elif term_type == "kitty":
        kitty_tab_switch(pid)
    # alacritty: window focus is sufficient, no tabs
