export type SessionStatus =
  | "idle"
  | "working"
  | "waiting_input"
  | "waiting_permission"
  | "needs_attention"
  | "compacting";

export interface RawSession {
  session_id: string;
  project_path: string;
  project_name: string;
  branch: string;
  status: SessionStatus;
  last_prompt: string | null;
  last_activity: string;
  started_at: string;
  terminal: { type: string; pid: number } | null;
  pid: number;
  pid_start_time: number | null;
  last_tool: string | null;
  last_tool_detail: string | null;
  notification_message: string | null;
  session_name: string | null;
  source: string | null;
  active_subagents: Array<{ agent_id: string; agent_type: string; started_at?: string }>;
  ended_at?: string | null;
  workspace_file?: string | null;
}

export interface Session extends RawSession {
  // Computed display fields (added by lib/sessions.ts)
  displayName: string;
  sourceLabel: string;
  statusLabel: string;
  statusColor: string;
  contextLine: string | null;
  relativeTime: string;
  subagentCount: number;
}

// Status priority for sorting (lower = higher priority)
export const STATUS_PRIORITY: Record<SessionStatus, number> = {
  waiting_permission: 0,
  waiting_input: 1,
  needs_attention: 1,
  working: 2,
  compacting: 2,
  idle: 3,
};

// Catppuccin Mocha status colors
export const STATUS_COLORS: Record<SessionStatus, string> = {
  waiting_permission: "#f38ba8",
  waiting_input: "#f9e2af",
  needs_attention: "#f9e2af",
  working: "#a6e3a1",
  compacting: "#89b4fa",
  idle: "#6c7086",
};

export const STATUS_LABELS: Record<SessionStatus, string> = {
  waiting_permission: "Permission",
  waiting_input: "Input",
  needs_attention: "Attention",
  working: "Working",
  compacting: "Compacting",
  idle: "Idle",
};
