import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { Session, DisplaySession, SessionStatus } from "./types";

export const STATUS_COLORS: Record<SessionStatus, string> = {
  waiting_permission: "#f38ba8",
  waiting_input:      "#f9e2af",
  needs_attention:    "#f9e2af",
  working:            "#a6e3a1",
  compacting:         "#89b4fa",
  idle:               "#6c7086",
};

export const STATUS_LABELS: Record<SessionStatus, string> = {
  waiting_permission: "Permission",
  waiting_input:      "Waiting",
  needs_attention:    "Attention",
  working:            "Working",
  compacting:         "Compacting",
  idle:               "Idle",
};

// Status priority for sort order (lower = higher priority)
const STATUS_PRIORITY: Record<SessionStatus, number> = {
  waiting_permission: 0,
  waiting_input:      1,
  needs_attention:    1,
  working:            2,
  compacting:         2,
  idle:               3,
};

export function computeContextLine(session: Session): string | null {
  const { status, last_tool, last_tool_detail, last_prompt, notification_message } = session;

  switch (status) {
    case "idle":
      return null;

    case "compacting":
      return "Compacting context...";

    case "waiting_permission":
      return notification_message || "Permission needed";

    case "waiting_input":
    case "needs_attention": {
      if (!last_prompt) return null;
      const excerpt = last_prompt.slice(0, 36);
      return `"${excerpt}"`;
    }

    case "working": {
      if (last_tool && last_tool_detail) {
        const detail = last_tool_detail;
        switch (last_tool.toLowerCase()) {
          case "bash":
            return `Running: ${detail.slice(0, 30)}`;
          case "edit":
            return `Editing ${basename(detail)}`;
          case "write":
            return `Writing ${basename(detail)}`;
          case "read":
            return `Reading ${basename(detail)}`;
          case "grep":
            return `Searching: ${detail.slice(0, 30)}`;
          default:
            return `${last_tool}: ${detail.slice(0, 30)}`;
        }
      } else if (last_prompt) {
        return `"${last_prompt.slice(0, 36)}"`;
      }
      return null;
    }

    default:
      return null;
  }
}

function basename(path: string): string {
  return path.split("/").pop() || path;
}

export function computeRelativeTime(isoString: string): string {
  const now = Date.now();
  const then = new Date(isoString).getTime();
  const diffMs = now - then;
  const diffSec = Math.floor(diffMs / 1000);

  if (diffSec < 5)  return "just now";
  if (diffSec < 60) return `${diffSec}s ago`;

  const diffMin = Math.floor(diffSec / 60);
  if (diffMin < 60) return `${diffMin}m ago`;

  const diffHr = Math.floor(diffMin / 60);
  if (diffHr < 24) return `${diffHr}h ago`;

  const diffDay = Math.floor(diffHr / 24);
  return `${diffDay}d ago`;
}

export function computeDisplayFields(session: Session): DisplaySession {
  return {
    ...session,
    displayName:  session.session_name || session.project_name,
    sourceLabel:  session.source === "opencode" ? "OC" : "CC",
    statusLabel:  STATUS_LABELS[session.status] ?? session.status,
    statusColor:  STATUS_COLORS[session.status] ?? "#6c7086",
    contextLine:  computeContextLine(session),
    relativeTime: computeRelativeTime(session.last_activity),
    subagentCount: (session.active_subagents ?? []).length,
  };
}

export function sortSessions(sessions: Session[]): Session[] {
  return [...sessions].sort((a, b) => {
    const pa = STATUS_PRIORITY[a.status] ?? 99;
    const pb = STATUS_PRIORITY[b.status] ?? 99;
    if (pa !== pb) return pa - pb;
    // Within same priority group, sort by last_activity descending
    return new Date(b.last_activity).getTime() - new Date(a.last_activity).getTime();
  });
}

export async function fetchSessions(): Promise<DisplaySession[]> {
  const raw = await invoke<Session[]>("list_sessions");
  return sortSessions(raw).map(computeDisplayFields);
}

export async function setupSessionsListener(
  callback: () => void
): Promise<() => void> {
  const unlisten = await listen("sessions-changed", callback);
  return unlisten;
}

// Pre-select the first "urgent" session (permission or waiting_input/needs_attention)
export function findDefaultSelection(sessions: DisplaySession[]): number {
  const urgent = sessions.findIndex(
    (s) =>
      s.status === "waiting_permission" ||
      s.status === "waiting_input" ||
      s.status === "needs_attention"
  );
  return urgent >= 0 ? urgent : 0;
}

// Count sessions by status group for the header dots
export interface StatusCounts {
  permission: number;
  attention: number;
  working: number;
  compacting: number;
  idle: number;
}

export function countByStatus(sessions: Session[]): StatusCounts {
  const counts: StatusCounts = {
    permission: 0,
    attention:  0,
    working:    0,
    compacting: 0,
    idle:       0,
  };
  for (const s of sessions) {
    switch (s.status) {
      case "waiting_permission": counts.permission++; break;
      case "waiting_input":
      case "needs_attention":    counts.attention++;  break;
      case "working":            counts.working++;    break;
      case "compacting":         counts.compacting++; break;
      case "idle":               counts.idle++;       break;
    }
  }
  return counts;
}
