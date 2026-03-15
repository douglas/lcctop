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
  starttime: number;
}

function parseProcStat(pid: number): ProcStat | null {
  try {
    const file = Gio.File.new_for_path(`/proc/${pid}/stat`);
    const [ok, contents] = file.load_contents(null);
    if (!ok) return null;
    const text = new TextDecoder().decode(contents);

    const parenOpen = text.indexOf("(");
    const parenClose = text.lastIndexOf(")");
    if (parenOpen === -1 || parenClose === -1) return null;

    const comm = text.slice(parenOpen + 1, parenClose);
    const rest = text.slice(parenClose + 2).trim().split(" ");

    // rest[0]=state rest[1]=ppid rest[4]=tty_nr rest[19]=starttime
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
// Hyprland: find window address
// ---------------------------------------------------------------------------

interface HyprClient {
  pid: number;
  address: string;
  stableId: number; // parsed from hex stableId field
}

function hyprctlClients(): HyprClient[] {
  try {
    const [ok, stdout, , exitCode] = GLib.spawn_command_line_sync("hyprctl clients -j");
    if (!ok || exitCode !== 0 || !stdout) return [];
    const text = new TextDecoder().decode(stdout);
    const raw = JSON.parse(text) as Array<{ pid: number; address: string; stableId?: string }>;
    return raw.map((c) => ({
      pid: c.pid,
      address: c.address,
      stableId: c.stableId ? parseInt(c.stableId, 16) : 0,
    }));
  } catch {
    return [];
  }
}

/** Walk from sessionPid up to termPid; return the direct child of termPid. */
function findTabRoot(sessionPid: number, termPid: number): number | null {
  let pid = sessionPid;
  for (let i = 0; i < 8; i++) {
    const stat = parseProcStat(pid);
    if (!stat) break;
    if (stat.ppid === termPid) return pid;
    if (stat.ppid <= 1) break;
    pid = stat.ppid;
  }
  return null;
}

/**
 * Enumerate direct children of termPid that have a controlling TTY,
 * sorted by starttime (oldest = window 1).
 */
function enumTabRoots(termPid: number): Array<{ pid: number; starttime: number }> {
  const tabRoots: Array<{ pid: number; starttime: number }> = [];
  const procDir = Gio.File.new_for_path("/proc");
  let enumerator: Gio.FileEnumerator;
  try {
    enumerator = procDir.enumerate_children("standard::name", Gio.FileQueryInfoFlags.NONE, null);
  } catch {
    return tabRoots;
  }

  let info: Gio.FileInfo | null;
  while ((info = enumerator.next_file(null)) !== null) {
    const name = info.get_name();
    if (!/^\d+$/.test(name)) continue;
    const childPid = parseInt(name, 10);
    const stat = parseProcStat(childPid);
    if (!stat) continue;
    if (stat.ppid !== termPid) continue;
    if (stat.ttyNr === 0) continue;
    tabRoots.push({ pid: childPid, starttime: stat.starttime });
  }
  enumerator.close(null);

  tabRoots.sort((a, b) => a.starttime - b.starttime);
  return tabRoots;
}

/**
 * When multiple ghostty windows share one PID, resolve the correct address.
 * stableId (entries) and starttime (tab roots) both increase monotonically
 * with window creation order, so the i-th tab root maps to the i-th entry.
 */
function ghosttyResolveAddress(
  termPid: number,
  tabRootPid: number | null,
  entries: HyprClient[],
): string {
  if (!tabRootPid) return entries[0].address;

  const tabRoots = enumTabRoots(termPid);
  if (tabRoots.length === 0) return entries[0].address;

  const idx = tabRoots.findIndex((t) => t.pid === tabRootPid);
  if (idx === -1 || idx >= entries.length) return entries[0].address;

  return entries[idx].address;
}

function findHyprWindowAddress(sessionPid: number, clients: HyprClient[]): string | null {
  if (!clients.length) return null;

  const chain = ppidChain(sessionPid);

  for (const p of chain) {
    const matching = clients.filter((c) => c.pid === p);
    if (!matching.length) continue;

    if (matching.length === 1) return matching[0].address;

    // Multiple windows share this PID (ghostty multi-window):
    // sort by stableId ascending (creation order) then use tab root to pick.
    matching.sort((a, b) => a.stableId - b.stableId);
    const tabRoot = findTabRoot(sessionPid, p);
    return ghosttyResolveAddress(p, tabRoot, matching);
  }

  return null;
}

// ---------------------------------------------------------------------------
// Ghostty tab switch
// ---------------------------------------------------------------------------

/**
 * Send Alt+N to switch to the correct tab within the focused ghostty window.
 * Skipped when multiple windows share the ghostty PID (Alt+N is per-window,
 * so a global tab index is ambiguous across windows).
 */
function ghosttyTabSwitch(termPid: number, sessionPid: number, clients: HyprClient[]): void {
  const windowCount = clients.filter((c) => c.pid === termPid).length;
  if (windowCount > 1) return;

  const tabChildren = enumTabRoots(termPid);
  if (!tabChildren.length) return;

  const chain = ppidChain(sessionPid);
  const chainSet = new Set(chain);

  let tabIndex = -1;
  for (let i = 0; i < tabChildren.length; i++) {
    if (chainSet.has(tabChildren[i].pid)) {
      tabIndex = i + 1; // 1-based
      break;
    }
  }

  if (tabIndex === -1 || tabIndex > 8) return;

  GLib.spawn_command_line_async(`wtype -M alt -k ${tabIndex}`);
}

// ---------------------------------------------------------------------------
// Kitty tab switch
// ---------------------------------------------------------------------------

function kittyTabSwitch(sessionPid: number): void {
  try {
    const [ok, stdout, , exitCode] = GLib.spawn_command_line_sync("kitty @ ls");
    if (!ok || exitCode !== 0 || !stdout) return;
    const text = new TextDecoder().decode(stdout);
    const osWindows = JSON.parse(text) as Array<{
      tabs: Array<{ id: number; windows: Array<{ pid: number }> }>;
    }>;

    for (const osWin of osWindows) {
      for (const tab of osWin.tabs) {
        for (const win of tab.windows) {
          if (win.pid === sessionPid) {
            GLib.spawn_command_line_async(`kitty @ focus-tab --match id:${tab.id}`);
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
  const clients = hyprctlClients();

  // 1. Focus the Hyprland window
  const address = findHyprWindowAddress(pid, clients);
  if (address) {
    GLib.spawn_command_line_async(`hyprctl dispatch focuswindow address:${address}`);
  }

  // 2. Terminal-specific tab switch
  const { type: termType, termPid } = detectTerminalType(pid);

  switch (termType) {
    case "ghostty":
      ghosttyTabSwitch(termPid, pid, clients);
      break;
    case "kitty":
      kittyTabSwitch(pid);
      break;
    case "alacritty":
      // Window focus is sufficient — no tabs
      break;
    default:
      break;
  }
}
