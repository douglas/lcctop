"""
Theme loader: reads lcctop-pick-colors.json and generates GTK4 CSS.
Falls back to Catppuccin Mocha hardcoded constants if the theme file is absent.
"""

import json
import os

_COLORS_PATH = os.path.expanduser(
    "~/.config/omarchy/current/theme/lcctop-pick-colors.json"
)

# Catppuccin Mocha fallbacks (key names match lcctop-pick-colors.json.tpl)
DEFAULTS: dict[str, str] = {
    "red":      "#f38ba8",
    "amber":    "#f9e2af",
    "green":    "#a6e3a1",
    "blue":     "#89b4fa",
    "purple":   "#cba6f7",
    "gray":     "#6c7086",
    "subtext":  "#a6adc8",
    "overlay1": "#7f849c",
    "text":     "#cdd6f4",
    "base":     "#1e1e2e",
    "mantle":   "#181825",
    "surface0": "#313244",
    "surface1": "#45475a",
}

# Maps SessionStatus → color key
STATUS_COLORS: dict[str, str] = {
    "waiting_permission": "red",
    "waiting_input":      "amber",
    "needs_attention":    "amber",
    "working":            "green",
    "compacting":         "blue",
    "idle":               "gray",
}

STATUS_LABELS: dict[str, str] = {
    "waiting_permission": "Permission",
    "waiting_input":      "Waiting",
    "needs_attention":    "Attention",
    "working":            "Working",
    "compacting":         "Compacting",
    "idle":               "Idle",
}

STATUS_PRIORITY: dict[str, int] = {
    "waiting_permission": 0,
    "waiting_input":      1,
    "needs_attention":    1,
    "working":            2,
    "compacting":         2,
    "idle":               3,
}

SOURCE_BADGE_KEY: dict[str, str] = {
    "CC": "amber",
    "OC": "blue",
}


def load_colors() -> dict[str, str]:
    """Load theme colors, merging over Catppuccin Mocha defaults."""
    try:
        with open(_COLORS_PATH) as f:
            data = json.load(f)
        return {**DEFAULTS, **data}
    except Exception:
        return dict(DEFAULTS)


def resolve(colors: dict[str, str], key: str) -> str:
    return colors.get(key, DEFAULTS.get(key, "#ffffff"))


def generate_css(colors: dict[str, str]) -> str:
    """Return complete GTK4 CSS string with theme colors substituted."""
    base     = resolve(colors, "base")
    mantle   = resolve(colors, "mantle")
    surface0 = resolve(colors, "surface0")
    surface1 = resolve(colors, "surface1")
    text     = resolve(colors, "text")
    subtext  = resolve(colors, "subtext")
    gray     = resolve(colors, "gray")
    purple   = resolve(colors, "purple")

    return f"""
.lcctop-picker-window {{
  background-color: transparent;
}}

.picker-scrim {{
  background-color: rgba(0,0,0,0.4);
}}

.picker-container {{
  background-color: {base};
  border: 1px solid {surface1};
  border-radius: 10px;
}}

.picker-header {{
  background-color: {mantle};
  border-radius: 10px 10px 0 0;
  border-bottom: 1px solid {surface0};
  padding: 10px 14px;
}}

.header-title {{
  font-weight: bold;
  color: {text};
  font-size: 1em;
}}

.picker-scroll {{
  background-color: {base};
}}

.session-card {{
  background-color: transparent;
  border-radius: 0;
  padding: 0;
  transition: background-color 100ms ease;
}}

.session-card.selected {{
  background-color: {surface0};
}}

.accent-bar {{
  min-width: 4px;
  border-radius: 0;
}}

.card-body {{
  padding: 8px 12px;
}}

.card-name {{
  font-weight: bold;
  color: {text};
  font-size: 0.95em;
}}

.card-agents {{
  color: {purple};
  font-size: 0.82em;
}}

.card-source {{
  font-size: 0.78em;
  font-weight: bold;
}}

.card-status {{
  font-size: 0.82em;
  font-weight: 600;
}}

.card-time {{
  color: {gray};
  font-size: 0.78em;
}}

.card-context {{
  color: {subtext};
  font-size: 0.8em;
}}

.dot-icon {{
  font-size: 0.7em;
}}

.dot-count {{
  font-size: 0.82em;
  font-weight: 600;
}}

.picker-footer {{
  background-color: {mantle};
  border-radius: 0 0 10px 10px;
  border-top: 1px solid {surface0};
  padding: 6px 14px;
}}

.footer-hint {{
  color: {gray};
  font-size: 0.78em;
}}
"""
