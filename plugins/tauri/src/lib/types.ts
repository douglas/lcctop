export type SessionStatus =
  | "idle"
  | "working"
  | "waiting_input"
  | "waiting_permission"
  | "needs_attention"
  | "compacting";

export interface Session {
  session_id: string;
  project_path: string;
  project_name: string;
  branch: string;
  status: SessionStatus;
  last_prompt: string | null;
  last_activity: string;
  started_at: string;
  terminal: { program: string; tty: string | null } | null;
  pid: number;
  pid_start_time: number | null;
  last_tool: string | null;
  last_tool_detail: string | null;
  notification_message: string | null;
  session_name: string | null;
  source: string | null;
  active_subagents: Array<{
    agent_id: string;
    agent_type: string;
    started_at: string;
  }>;
}

export interface DisplaySession extends Session {
  displayName: string;
  sourceLabel: string;
  statusLabel: string;
  statusColor: string;
  contextLine: string | null;
  relativeTime: string;
  subagentCount: number;
}
