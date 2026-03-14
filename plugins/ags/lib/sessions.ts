import GLib from "gi://GLib";
import Gio from "gi://Gio";
import { Variable } from "astal";
import {
  Session,
  RawSession,
  SessionStatus,
  STATUS_PRIORITY,
  STATUS_COLORS,
  STATUS_LABELS,
} from "./types.js";

// ---------------------------------------------------------------------------
// Proc helpers
// ---------------------------------------------------------------------------

/** Read /proc/{pid}/stat and return fields array, or null if missing. */
function readProcStat(pid: number): string[] | null {
  const path = `/proc/${pid}/stat`;
  try {
    const file = Gio.File.new_for_path(path);
    const [ok, contents] = file.load_contents(null);
    if (!ok) return null;
    const text = new TextDecoder().decode(contents);
    // comm field can contain spaces and parens — split after the closing paren
    const parenClose = text.lastIndexOf(")");
    if (parenClose === -1) return null;
    const before = text.slice(0, text.indexOf("("));
    const comm = text.slice(text.indexOf("(") + 1, parenClose);
    const after = text.slice(parenClose + 2); // skip ") "
    const parts = [before.trim(), comm, ...after.trim().split(" ")];
    return parts;
  } catch {
    return null;
  }
}

/** Return true if the process is alive and not a zombie. */
function isAlive(pid: number): boolean {
  const stat = readProcStat(pid);
  if (!stat) return false;
  // fields[2] is state after comm, which is index 2 in our array
  const state = stat[2];
  return state !== "Z" && state !== "X";
}

// ---------------------------------------------------------------------------
// Relative time formatting
// ---------------------------------------------------------------------------

function relativeTime(isoStr: string): string {
  const now = GLib.get_real_time() / 1_000_000; // microseconds → seconds
  const then = new Date(isoStr).getTime() / 1000;
  const diff = Math.max(0, now - then);

  if (diff < 60) return "just now";
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}

// ---------------------------------------------------------------------------
// Context line
// ---------------------------------------------------------------------------

function buildContextLine(s: RawSession): string | null {
  switch (s.status) {
    case "idle":
      return null;
    case "compacting":
      return "Compacting context...";
    case "waiting_permission":
      return s.notification_message ?? "Permission needed";
    case "waiting_input":
    case "needs_attention": {
      if (!s.last_prompt) return null;
      const truncated = s.last_prompt.slice(0, 36);
      return `"${truncated}${s.last_prompt.length > 36 ? "…" : ""}"`;
    }
    case "working": {
      if (!s.last_tool) return null;
      const detail = s.last_tool_detail ?? "";
      const tool = s.last_tool.toLowerCase();
      if (tool === "bash") return `Running: ${detail}`;
      if (tool === "edit" || tool === "multiedit") return `Editing ${detail}`;
      if (tool === "read") return `Reading ${detail}`;
      if (tool === "write") return `Writing ${detail}`;
      if (tool === "glob") return `Searching ${detail}`;
      if (tool === "grep") return `Grepping ${detail}`;
      if (tool === "task" || tool === "agent") return `Agent: ${detail}`;
      return `${s.last_tool}: ${detail}`;
    }
    default:
      return null;
  }
}

// ---------------------------------------------------------------------------
// Enrich raw session with display fields
// ---------------------------------------------------------------------------

function enrichSession(raw: RawSession): Session {
  const status = raw.status as SessionStatus;
  const sourceLower = (raw.source ?? "").toLowerCase();
  const sourceLabel = sourceLower === "opencode" ? "OC" : "CC";

  return {
    ...raw,
    displayName: raw.session_name ?? raw.project_name,
    sourceLabel,
    statusLabel: STATUS_LABELS[status] ?? status,
    statusColor: STATUS_COLORS[status] ?? "#6c7086",
    contextLine: buildContextLine(raw),
    relativeTime: relativeTime(raw.last_activity),
    subagentCount: (raw.active_subagents ?? []).length,
  };
}

// ---------------------------------------------------------------------------
// Sort sessions
// ---------------------------------------------------------------------------

function sortSessions(sessions: Session[]): Session[] {
  return [...sessions].sort((a, b) => {
    const pa = STATUS_PRIORITY[a.status as SessionStatus] ?? 99;
    const pb = STATUS_PRIORITY[b.status as SessionStatus] ?? 99;
    if (pa !== pb) return pa - pb;
    // Secondary: last_activity descending
    return new Date(b.last_activity).getTime() - new Date(a.last_activity).getTime();
  });
}

// ---------------------------------------------------------------------------
// Load sessions from ~/.cctop/sessions/*.json
// ---------------------------------------------------------------------------

const SESSIONS_DIR = GLib.build_filenamev([GLib.get_home_dir(), ".cctop", "sessions"]);

export function loadSessions(): Session[] {
  const dir = Gio.File.new_for_path(SESSIONS_DIR);

  let enumerator: Gio.FileEnumerator;
  try {
    enumerator = dir.enumerate_children(
      "standard::name,standard::type",
      Gio.FileQueryInfoFlags.NONE,
      null,
    );
  } catch {
    return [];
  }

  const sessions: Session[] = [];
  let info: Gio.FileInfo | null;

  while ((info = enumerator.next_file(null)) !== null) {
    const name = info.get_name();
    if (!name.endsWith(".json")) continue;

    const file = dir.get_child(name);
    let raw: RawSession;
    try {
      const [ok, contents] = file.load_contents(null);
      if (!ok) continue;
      raw = JSON.parse(new TextDecoder().decode(contents)) as RawSession;
    } catch {
      continue;
    }

    // Liveness check
    if (raw.pid && !isAlive(raw.pid)) continue;

    sessions.push(enrichSession(raw));
  }

  enumerator.close(null);
  return sortSessions(sessions);
}

// ---------------------------------------------------------------------------
// Reactive sessions variable — polls every 2 seconds
// ---------------------------------------------------------------------------

export const sessions = Variable<Session[]>(loadSessions());

let _pollId: number | null = null;

export function startPolling(): void {
  if (_pollId !== null) return;
  _pollId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 2000, () => {
    sessions.set(loadSessions());
    return GLib.SOURCE_CONTINUE;
  });
}

export function stopPolling(): void {
  if (_pollId !== null) {
    GLib.source_remove(_pollId);
    _pollId = null;
  }
}
