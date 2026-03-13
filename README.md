# lcctop

A Linux port of [cctop](https://github.com/steipete/cctop) — monitors Claude Code sessions for Waybar/Hyprland.

Uses Claude Code hooks to track session state in `~/.cctop/sessions/{pid}.json` (same format as macOS cctop), then surfaces status in a Waybar custom module.

## Components

- **`lcctop-hook`** — receives Claude Code hook events via stdin, writes session JSON files
- **`lcctop-waybar`** — reads session files, outputs Waybar-compatible JSON (Phase 2)

## Installation

```sh
rake install          # symlinks bin/ into ~/.local/bin/
rake install_plugin   # symlinks plugins/cctop into ~/.claude/plugins/
```

## Session Format

Compatible with cctop's `~/.cctop/sessions/{pid}.json`. Fields:

| Field | Type | Description |
|-------|------|-------------|
| `session_id` | string | Claude Code session identifier |
| `project_path` | string | Working directory |
| `project_name` | string | basename of project_path |
| `branch` | string | Current git branch |
| `status` | string | `idle`, `working`, `compacting`, `waiting_permission`, `waiting_input`, `needs_attention` |
| `last_prompt` | string? | Most recent user prompt |
| `last_activity` | ISO8601 | Timestamp of last hook event |
| `started_at` | ISO8601 | Session start time |
| `terminal` | object? | `{program, session_id, tty}` |
| `pid` | integer? | Claude Code process PID |
| `pid_start_time` | float? | PID start time (seconds since epoch) for PID reuse detection |
| `last_tool` | string? | Most recent tool name |
| `last_tool_detail` | string? | Most recent tool argument (command, path, query, etc.) |
| `notification_message` | string? | Permission or notification text |
| `session_name` | string? | Custom title from Claude Code transcript |
| `workspace_file` | string? | `.code-workspace` file path |
| `active_subagents` | array? | `[{agent_id, agent_type, started_at}]` |

## Status State Machine

```
SessionStart       → idle
UserPromptSubmit   → working
PreToolUse         → working
PostToolUse        → working
Stop               → waiting_input
Notification(idle) → waiting_input
PermissionRequest  → waiting_permission
PreCompact         → compacting
PostCompact        → idle
SessionError       → needs_attention
SessionEnd         → (file removed)
SubagentStart/Stop → (no status change)
```

## Linux-Specific Implementation

- **Process liveness**: `/proc/{pid}/stat` replaces macOS `sysctl`
- **Start time**: `btime` from `/proc/stat` + `starttime` ticks from `/proc/{pid}/stat`
- **PPID walk**: reads `/proc/{pid}/comm` to skip shell intermediaries
- **TTY detection**: walks parent PIDs checking `tty_nr` in `/proc/{pid}/stat`

## Development

```sh
rake test   # run full test suite
```

Requires Ruby stdlib only (no gem dependencies at runtime).
