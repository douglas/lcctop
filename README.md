# lcctop

A Linux port of [cctop](https://github.com/steipete/cctop) — monitors Claude Code sessions for Waybar/Hyprland.

Uses Claude Code hooks to track session state in `~/.cctop/sessions/{pid}.json` (same format as macOS cctop), then surfaces status in a Waybar custom module.

## Components

- **`lcctop-hook`** — receives Claude Code hook events via stdin, writes session JSON files
- **`lcctop-waybar`** — watches session files, outputs Waybar-compatible JSON continuously
- **`lcctop-pick`** — ratatui_ruby TUI session picker: j/k navigate, Enter focuses window, Esc/q cancel

## Installation

```sh
rake install          # symlinks bin/ into ~/.local/bin/
rake install_plugin   # symlinks plugin + registers hooks in ~/.claude/settings.local.json
rake install_theme    # copies CSS template + generates current theme CSS
rake install_opencode # copies opencode plugin.js to ~/.config/opencode/plugins/cctop.js
```

To register lcctop hooks in a **project-level** `.claude/settings.local.json` (needed when the
project has its own settings that would override the user-level hooks):

```sh
rake 'install_hooks[/path/to/project]'
```

Then restart Waybar (`omarchy-restart-waybar`) and start a **new Claude Code session** —
hooks are loaded at session start, so the current session won't show up.

On subsequent theme switches, `omarchy-theme-set` automatically regenerates
`~/.config/omarchy/current/theme/lcctop-waybar.css` from the template.
Colors update live via `reload_style_on_change: true` — no waybar restart needed.

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

## Waybar Integration

Add to `~/.config/waybar/config.jsonc` (in `modules-right`, before `cpu`):

```jsonc
"custom/lcctop": {
  "exec": "lcctop-waybar",
  "return-type": "json",
  "format": "{}",
  "tooltip": true,
  "on-click": "hyprctl dispatch focuswindow 'title:.*claude.*'",
  "signal": 11
}
```

Add to `~/.config/waybar/style.css`:

```css
@import "../omarchy/current/theme/lcctop-waybar.css";

#custom-lcctop { margin: 0 7.5px; min-width: 12px; }
#custom-lcctop.permission { color: @lcctop-permission; }
#custom-lcctop.attention  { color: @lcctop-attention;  }
#custom-lcctop.working    { color: @lcctop-working;    }
#custom-lcctop.idle       { color: @lcctop-idle;       }
#custom-lcctop.compacting { color: @lcctop-compacting; }
```

Install the theme templates (run once, then auto-updates on theme switch):

```sh
rake install_theme   # copies lcctop-waybar.css.tpl + lcctop-pick-colors.json.tpl, generates current outputs
```

### Waybar tooltip layout

The tooltip matches cctop's card layout:

```
cctop    ● 1  ● 2  ● 1          ← colored dots: red=permission, amber=attention, green=working, gray=idle
────────────────────
▍ project-name  [2 agents]  CC    Permission
  main / Permission needed                    just now
────────────────────
▍ other-project  OC    Working
  feature-branch / Running: npm test          5m ago
```

Source badge colors: **CC** = amber (`#f9e2af`), **OC** = blue (`#89b4fa`)

### Waybar output format

| Field | Values |
|-------|--------|
| `text` | `"󰚩"` (1 session) or `"󰚩 N"` (N sessions), `""` hides module |
| `class` | `permission` / `attention` / `working` / `compacting` / `idle` |
| `tooltip` | Header with status dot counts, then per-session cards |

### Display adjustments (view-only, files not modified)

- **Idle timeout**: `waiting_input` for > 60 min → displayed as `idle`
- **Permission + child**: `waiting_permission` + a child process started after the permission request → displayed as `working`

## Opencode Support

lcctop can also track [opencode](https://opencode.ai) sessions via an in-process JS plugin.

```sh
rake install_opencode   # copies plugins/opencode/plugin.js to ~/.config/opencode/plugins/cctop.js
```

Then add the plugin to your `opencode.json`:

```json
{
  "plugin": ["file://~/.config/opencode/plugins/cctop.js"]
}
```

Opencode sessions appear in the Waybar tooltip with an **OC** badge (blue). The session files
are written to `~/.cctop/sessions/{pid}.json` with `"source": "opencode"`, fully compatible
with the cctop format.

## Linux-Specific Implementation

- **Process liveness**: `/proc/{pid}/stat` replaces macOS `sysctl`
- **Start time**: `btime` from `/proc/stat` + `starttime` ticks from `/proc/{pid}/stat`
- **PPID walk**: reads `/proc/{pid}/comm` to skip shell intermediaries
- **TTY detection**: walks parent PIDs checking `tty_nr` in `/proc/{pid}/stat`

## Session Picker

`lcctop-pick` opens a floating TUI window showing all active sessions with colors, status, and
branch/context info. Press Enter to focus the selected session's terminal window — including
switching to the correct tab for Ghostty (`wtype Alt+N`) and Kitty (`kitty @ focus-tab`).
Alacritty has no tabs; window focus is sufficient.

Colors follow the active Omarchy theme automatically. Run `rake install_theme` once to register
the template; after that, `omarchy-theme-set` regenerates colors on every theme switch.

Invoke via keybind (see xremap example below) or by clicking the Waybar icon.

### Hyprland floating window rule

Add to `~/.config/hypr/windows.conf` (or equivalent):

```
windowrule = float on, center on, size 700 400, match:initial_class org.omarchy.Lcctop
```

### xremap keybind (F18+Home)

Add a global keymap entry **before** any `application:`-filtered sections:

```yaml
- name: lcctop
  remap:
    F18-Home: { launch: ["setsid", "uwsm-app", "--", "ghostty",
                         "--class=org.omarchy.Lcctop", "--title=lcctop",
                         "-e", "/home/douglas/.local/bin/lcctop-pick"] }
```

> **Note:** Use the full absolute path — uwsm-app runs in a clean systemd environment without
> `~/.local/bin` in PATH.

### Waybar on-click

```jsonc
"on-click": "setsid uwsm-app -- ghostty --class=org.omarchy.Lcctop --title=lcctop -e /home/douglas/.local/bin/lcctop-pick",
```

## Development

```sh
rake test   # run full test suite
```

Runtime dependency: `ratatui_ruby` (required by `lcctop-pick`).
