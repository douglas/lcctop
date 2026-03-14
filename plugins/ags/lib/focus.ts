import GLib from "gi://GLib";
import Gio from "gi://Gio";
import { Session } from "./types.js";

// ---------------------------------------------------------------------------
// Proc helpers
// ---------------------------------------------------------------------------

interface ProcStat {
  pid: number;
  comm: string;
  state: string;
  ppid: number;
  ttyNr: number;
  starttime: number; // clock ticks since system boot (field index 21)
}

function parseProcStat(pid: number): ProcStat | null {
  const path = `/proc/${pid}/stat`;
  try {
    const file = Gio.File.new_for_path(path);
    const [ok, contents] = file.load_contents(null);
    if (!ok) return null;
    const text = new TextDecoder().decode(contents);

    const parenOpen = text.indexOf("(");
    const parenClose = text.lastIndexOf(")");
    if (parenOpen === -1 || parenClose === -1) return null;

    const pidStr = text.slice(0, parenOpen).trim();
    const comm = text.slice(parenOpen + 1, parenClose);
    const rest = text.slice(parenClose + 2).trim().split(" ");

    // rest[0] = state, rest[1] = ppid, rest[4] = tty_nr, rest[19] = starttime
    return {
      pid,
      comm,
      state: rest[0],
      ppid: parseInt(rest[1], 10),
      ttyNr: parseInt(rest[4], 10),
      starttime: parseInt(rest[19], 10),
    };
  } catch {
    return null;
  }
}

function readComm(pid: number): string | null {
  try {
    const file = Gio.File.new_for_path(`/proc/${pid}/comm`);
    const [ok, contents] = file.load_contents(null);
    if (!ok) return null;
    return new TextDecoder().decode(contents).trim();
  } catch {
    return null;
  }
}

/** Walk /proc ppid chain from pid upward; returns array of PIDs (child first). */
function ppidChain(pid: number): number[] {
  const chain: number[] = [];
  let current = pid;
  const visited = new Set<number>();

  while (current > 1 && !visited.has(current)) {
    visited.add(current);
    chain.push(current);
    const stat = parseProcStat(current);
    if (!stat) break;
    current = stat.ppid;
  }

  return chain;
}

// ---------------------------------------------------------------------------
// Terminal detection
// ---------------------------------------------------------------------------

type TerminalType = "ghostty" | "kitty" | "alacritty" | "unknown";

function detectTerminalType(pid: number): { type: TerminalType; termPid: number } {
  const chain = ppidChain(pid);

  for (const p of chain) {
    const comm = readComm(p);
    if (!comm) continue;
    const c = comm.toLowerCase();
    if (c.includes("ghostty")) return { type: "ghostty", termPid: p };
    if (c.includes("kitty")) return { type: "kitty", termPid: p };
    if (c.includes("alacritty")) return { type: "alacritty", termPid: p };
  }

  return { type: "unknown", termPid: 0 };
}

// ---------------------------------------------------------------------------
// Hyprland: find window address by walking ppid chain
// ---------------------------------------------------------------------------

function hyprctlClients(): Array<{ pid: number; address: string }> {
  try {
    const [ok, stdout, , exitCode] = GLib.spawn_command_line_sync("hyprctl clients -j");
    if (!ok || exitCode !== 0 || !stdout) return [];
    const text = new TextDecoder().decode(stdout);
    const clients = JSON.parse(text) as Array<{ pid: number; address: string }>;
    return clients;
  } catch {
    return [];
  }
}

function findHyprWindowAddress(pid: number): string | null {
  const clients = hyprctlClients();
  if (!clients.length) return null;

  const clientPids = new Set(clients.map((c) => c.pid));
  const chain = ppidChain(pid);

  for (const p of chain) {
    if (clientPids.has(p)) {
      const client = clients.find((c) => c.pid === p);
      return client?.address ?? null;
    }
  }

  return null;
}

// ---------------------------------------------------------------------------
// Ghostty tab switch
// ---------------------------------------------------------------------------

/**
 * Ghostty uses Alt+N for tab switching (1-based index).
 * We find direct children of the ghostty pid that have a controlling TTY
 * (tty_nr != 0), sort them by starttime, and find the 1-based index of the
 * child whose ppid chain includes our target pid.
 */
function ghosttyTabSwitch(termPid: number, sessionPid: number): void {
  // Enumerate all pids to find direct children of termPid with a TTY
  const procDir = Gio.File.new_for_path("/proc");
  let enumerator: Gio.FileEnumerator;
  try {
    enumerator = procDir.enumerate_children(
      "standard::name,standard::type",
      Gio.FileQueryInfoFlags.NONE,
      null,
    );
  } catch {
    return;
  }

  type TabChild = { pid: number; starttime: number };
  const tabChildren: TabChild[] = [];
  let info: Gio.FileInfo | null;

  while ((info = enumerator.next_file(null)) !== null) {
    const name = info.get_name();
    if (!/^\d+$/.test(name)) continue;
    const childPid = parseInt(name, 10);
    const stat = parseProcStat(childPid);
    if (!stat) continue;
    if (stat.ppid !== termPid) continue;
    if (stat.ttyNr === 0) continue; // no controlling TTY → not a tab root shell
    tabChildren.push({ pid: childPid, starttime: stat.starttime });
  }
  enumerator.close(null);

  if (!tabChildren.length) return;

  // Sort by starttime ascending (oldest tab = index 1)
  tabChildren.sort((a, b) => a.starttime - b.starttime);

  // Find which tab root is an ancestor of sessionPid
  const chain = ppidChain(sessionPid);
  const chainSet = new Set(chain);

  let tabIndex = -1;
  for (let i = 0; i < tabChildren.length; i++) {
    if (chainSet.has(tabChildren[i].pid)) {
      tabIndex = i + 1; // 1-based
      break;
    }
  }

  if (tabIndex === -1) return;

  // Send Alt+N via wtype
  GLib.spawn_command_line_async(`wtype -M alt -k ${tabIndex}`);
}

// ---------------------------------------------------------------------------
// Kitty tab switch
// ---------------------------------------------------------------------------

interface KittyWindow {
  id: number;
  pid: number;
  tab_id: number;
}

interface KittyTab {
  id: number;
  windows: KittyWindow[];
}

interface KittyOS {
  tabs: KittyTab[];
}

function kittyTabSwitch(sessionPid: number): void {
  try {
    const [ok, stdout, , exitCode] = GLib.spawn_command_line_sync("kitty @ ls");
    if (!ok || exitCode !== 0 || !stdout) return;
    const text = new TextDecoder().decode(stdout);
    const osWindows = JSON.parse(text) as KittyOS[];

    for (const osWin of osWindows) {
      for (const tab of osWin.tabs) {
        for (const win of tab.windows) {
          if (win.pid === sessionPid) {
            GLib.spawn_command_line_async(
              `kitty @ focus-tab --match id:${tab.id}`,
            );
            return;
          }
        }
      }
    }
  } catch {
    // kitty not available or not running
  }
}

// ---------------------------------------------------------------------------
// Main focus entry point
// ---------------------------------------------------------------------------

export function focusSession(session: Session): void {
  const pid = session.pid;

  // 1. Focus the Hyprland window
  const address = findHyprWindowAddress(pid);
  if (address) {
    GLib.spawn_command_line_async(`hyprctl dispatch focuswindow address:${address}`);
  }

  // 2. Terminal-specific tab switch
  const { type: termType, termPid } = detectTerminalType(pid);

  switch (termType) {
    case "ghostty":
      ghosttyTabSwitch(termPid, pid);
      break;
    case "kitty":
      kittyTabSwitch(pid);
      break;
    case "alacritty":
      // Window focus is sufficient — no tabs
      break;
    default:
      // Unknown terminal — window focus was already done
      break;
  }
}
