# lcctop

A Linux port of [cctop](https://github.com/steipete/cctop) — monitors Claude Code, Codex, and opencode sessions for Waybar/Hyprland.

Uses Claude Code hooks, a Codex watcher, and an opencode plugin to track session state in `~/.cctop/sessions/{pid}.json` (same format as macOS cctop), then surfaces status in a Waybar custom module.

## Components

- **`lcctop-hook`** — receives Claude Code hook events via stdin, writes session JSON files
- **`lcctop-codex`** — watches `~/.codex/sessions/**/*.jsonl`, mirrors active Codex sessions into lcctop session files
- **`lcctop-waybar`** — watches session files, outputs Waybar-compatible JSON continuously
- **`lcctop-pick`** — ratatui_ruby TUI session picker: j/k navigate, Enter focuses window, Esc/q cancel; uses saved `hypr_address` for reliable focus (falls back to process-tree correlation)
- **`lcctop-pick-gtk`** — PyGTK4 layer-shell session picker: D-Bus singleton toggle, auto-refresh via inotify, theme-aware colors from Omarchy

## Installation

```sh
rake install          # symlinks bin/ into ~/.local/bin/
rake install_plugin   # symlinks plugin + registers hooks in ~/.claude/settings.json
rake install_codex    # installs/enables the Codex watcher user service
rake install_theme    # copies CSS template + generates current theme CSS
rake install_opencode # copies opencode plugin.js to ~/.config/opencode/plugins/cctop.js
rake install_ags      # copies AGS picker + bar widget to ~/.config/ags/lcctop/
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
| `terminal` | object? | `{program, session_id, tty, hypr_address}` |
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
  "markup": true,
  "tooltip": true,
  "on-click": "lcctop-pick-gtk",
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
▍ project-name  2 agents  CC              Permission
  main / Permission needed                  just now
────────────────────
▍ other-project  OC                          Working
  feature-branch / Running: npm test          5m ago
```

Source badge colors: **CC** = amber (`#f9e2af`), **CX** = blue (`#89b4fa`), **OC** = blue (`#89b4fa`)

### Waybar output format

| Field | Values |
|-------|--------|
| `text` | Pango-marked-up icon + colored status dots, e.g. `"󰚩  <span color='#a6e3a1'>● 1</span>  <span color='#6c7086'>● 2</span>"`. Requires `"format": "{}"` + `"markup": true` in waybar config. `""` hides module |
| `class` | `permission` / `attention` / `working` / `compacting` / `idle` |
| `tooltip` | Header with status dot counts, then per-session cards |

### Display adjustments (view-only, files not modified)

- **Idle timeout**: `waiting_input` for > 60 min → displayed as `idle`
- **Permission + child**: `waiting_permission` + a child process started after the permission request → displayed as `working`

## Session Picker

Two pickers are available:

### `lcctop-pick` (TUI / ratatui)

Opens a floating terminal window showing all active sessions with colors, status, and
branch/context info. Press Enter to focus the selected session's terminal window — including
switching to the correct tab for Ghostty (`wtype Alt+N`) and Kitty (`kitty @ focus-tab`).

### `lcctop-pick-gtk` (GTK4 layer-shell overlay)

A PyGTK4 layer-shell picker that renders as a full-screen overlay. D-Bus singleton toggle —
run once to open, run again to close. Auto-refreshes via inotify on `~/.cctop/sessions/`.
Theme-aware: reads colors from `~/.config/omarchy/current/theme/lcctop-pick-colors.json`.

Both pickers use the saved `hypr_address` (captured at SessionStart) to focus the correct
Hyprland window reliably, even across multiple terminal windows sharing a single PID.
Falls back to process-tree correlation for sessions without a saved address.

Colors follow the active Omarchy theme automatically. Run `rake install_theme` once to register
the template; after that, `omarchy-theme-set` regenerates colors on every theme switch.

Invoke via keybind (see xremap example below) or by clicking the Waybar icon.

### Hyprland floating window rule (for TUI picker)

Add to `~/.config/hypr/windows.conf` (or equivalent):

```
windowrule = float on, center on, size 700 400, match:initial_class org.omarchy.Lcctop
```

### xremap keybind (F18+Home)

Add a global keymap entry **before** any `application:`-filtered sections:

```yaml
- name: lcctop
  remap:
    F18-Home: { launch: ["lcctop-pick-gtk"] }
```

### Waybar on-click

```jsonc
"on-click": "lcctop-pick-gtk",
```

## AGS Bar Widget

`plugins/ags/` contains a small [AGS/Astal](https://aylur.github.io/astal/) bar widget
that shows colored session status dots in the bottom-right corner of the screen.
Clicking it opens `lcctop-pick-gtk`.

### Install and run

```sh
rake install_ags   # copies plugins/ags/ to ~/.config/ags/lcctop/
ags run ~/.config/ags/lcctop/app.tsx --gtk 4
```

### Toggle

```sh
ags request 'toggle lcctop-bar'
```

### What it shows

- `󰚩` icon colored by highest-priority status
- Session count when > 1
- Colored dots per status tier (red = permission, amber = attention, green = working, gray = idle)

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

## Codex Support

lcctop can also track local Codex CLI sessions by watching the session JSONL logs under
`~/.codex/sessions/` and mirroring active sessions into `~/.cctop/sessions/`.

```sh
rake install_codex
```

That installs `lcctop-codex`, copies a user `systemd` service, and tries to enable it.
Codex sessions appear with a **CX** badge (blue), using the same Omarchy-driven theme palette
as the rest of lcctop.

## Tauri Panel (Prototype)

`plugins/tauri/` is a floating web-UI session picker built with
[Tauri v2](https://tauri.app/) (Rust backend) and
[Svelte 5](https://svelte.dev/) (frontend).
It provides the same session list, status colors, and focus logic as `lcctop-pick`,
but rendered in a transparent WebView overlay window.

### Build and install

```sh
# Install JS deps first (once):
cd plugins/tauri && npm install

# Build release binary:
rake build_tauri

# Symlink to ~/.local/bin/lcctop-panel:
rake install_tauri
```

### Dev mode

```sh
cd plugins/tauri
cargo tauri dev
```

Vite hot-reloads the frontend on port 1420; Rust recompiles on save.

### Hyprland window rules

Add to `~/.config/hypr/hyprland.conf`:

```ini
windowrulev2 = float,    class:^(lcctop-tauri)$
windowrulev2 = pin,      class:^(lcctop-tauri)$
windowrulev2 = noborder, class:^(lcctop-tauri)$
windowrulev2 = noshadow, class:^(lcctop-tauri)$
windowrulev2 = size 420 500, class:^(lcctop-tauri)$
windowrulev2 = move 50% 30, class:^(lcctop-tauri)$
```

### Keybind suggestion (xremap)

```yaml
- name: lcctop-panel
  remap:
    F18-Home: { launch: ["setsid", "uwsm-app", "--", "lcctop-panel"] }
```

Or in Hyprland directly:

```ini
bind = SUPER, grave, exec, lcctop-panel
```

### Keyboard shortcuts

| Key | Action |
|-----|--------|
| `j` / `↓` | Next session |
| `k` / `↑` | Previous session |
| `Enter` | Focus selected session (raises window + switches tab) |
| `q` / `Esc` | Hide panel |

### Appearance

- Catppuccin Mocha color scheme with `backdrop-filter: blur`
- 420×500 px transparent borderless window
- Per-session left accent bar colored by status
- Header shows colored dot counts per status tier
- Source badge: **CC** (amber) = Claude Code, **CX** (blue) = Codex, **OC** (blue) = opencode
- Auto-refreshes via `notify`-based file watcher on `~/.cctop/sessions/`

## Linux-Specific Implementation

- **Process liveness**: `/proc/{pid}/stat` replaces macOS `sysctl`
- **Start time**: `btime` from `/proc/stat` + `starttime` ticks from `/proc/{pid}/stat`
- **PPID walk**: reads `/proc/{pid}/comm` to skip shell intermediaries
- **TTY detection**: walks parent PIDs checking `tty_nr` in `/proc/{pid}/stat`

## Development

```sh
rake test   # run full test suite
```

Runtime dependencies:
- `ratatui_ruby` — required by `lcctop-pick`
- Python 3 + `PyGObject` (GTK4 bindings) + `gtk4-layer-shell` — required by `lcctop-pick-gtk`
