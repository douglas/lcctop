import GLib from "gi://GLib";
import App from "astal/gtk3/app";
import Astal from "gi://Astal";
import { bind } from "astal";
import SessionPicker from "./widget/SessionPicker.js";
import StatusDot from "./widget/StatusDot.js";
import { sessions, startPolling } from "./lib/sessions.js";
import { STATUS_COLORS } from "./lib/types.js";

// ---------------------------------------------------------------------------
// Floating session picker window (700×450, layer=TOP, centered)
// ---------------------------------------------------------------------------

function LcctopPickerWindow() {
  return (
    <window
      name="lcctop-picker"
      namespace="lcctop-picker"
      cssClasses={["lcctop-picker-window"]}
      layer={Astal.Layer.TOP}
      // Full-screen anchor so we can center the inner container
      anchor={
        Astal.WindowAnchor.TOP |
        Astal.WindowAnchor.BOTTOM |
        Astal.WindowAnchor.LEFT |
        Astal.WindowAnchor.RIGHT
      }
      exclusivity={Astal.Exclusivity.IGNORE}
      keymode={Astal.Keymode.ON_DEMAND}
      visible={false}
      // Click the scrim (outside picker) to close
      onButtonPressEvent={() => {
        App.toggle_window("lcctop-picker");
        return true;
      }}
    >
      {/* Transparent scrim fills the full layer-shell surface */}
      <box
        cssClasses={["picker-scrim"]}
        hexpand={true}
        vexpand={true}
        css="background-color: alpha(#000000, 0.4);"
        halign={3 /* CENTER */}
        valign={3 /* CENTER */}
      >
        {/* The actual picker card — stop click propagation */}
        <box
          cssClasses={["picker-container"]}
          css="min-width: 700px; min-height: 450px; max-width: 700px; max-height: 450px;"
          halign={3 /* CENTER */}
          valign={3 /* CENTER */}
          onButtonPressEvent={() => true}
        >
          <SessionPicker />
        </box>
      </box>
    </window>
  );
}

// ---------------------------------------------------------------------------
// Small bar widget (bottom-right) showing session status dots
// ---------------------------------------------------------------------------

function LcctopBarWindow() {
  return (
    <window
      name="lcctop-bar"
      namespace="lcctop-bar"
      cssClasses={["lcctop-bar-window"]}
      layer={Astal.Layer.TOP}
      anchor={Astal.WindowAnchor.BOTTOM | Astal.WindowAnchor.RIGHT}
      exclusivity={Astal.Exclusivity.EXCLUSIVE}
      keymode={Astal.Keymode.NONE}
      visible={true}
      onButtonPressEvent={() => {
        App.toggle_window("lcctop-picker");
        return true;
      }}
    >
      {bind(sessions).as((list) => {
        const permCount = list.filter((s) => s.status === "waiting_permission").length;
        const attnCount = list.filter(
          (s) => s.status === "waiting_input" || s.status === "needs_attention",
        ).length;
        const workCount = list.filter(
          (s) => s.status === "working" || s.status === "compacting",
        ).length;
        const idleCount = list.filter((s) => s.status === "idle").length;
        const totalCount = list.length;

        if (totalCount === 0) {
          // Render an invisible 1px box so the window doesn't disappear entirely
          return <box css="min-width: 1px; min-height: 1px;" />;
        }

        const iconColor =
          permCount > 0
            ? STATUS_COLORS["waiting_permission"]
            : attnCount > 0
            ? STATUS_COLORS["waiting_input"]
            : workCount > 0
            ? STATUS_COLORS["working"]
            : STATUS_COLORS["idle"];

        return (
          <box
            orientation={0}
            spacing={6}
            cssClasses={["bar-widget"]}
            css="padding: 4px 8px; background-color: #1e1e2e; border-radius: 6px; margin: 4px;"
          >
            {/* Nerd font Claude icon */}
            <label label="󰚩" css={`color: ${iconColor}; font-size: 1em;`} />

            {/* Session count when > 1 */}
            {totalCount > 1 && (
              <label label={String(totalCount)} css="color: #cdd6f4; font-size: 0.85em;" />
            )}

            {/* Status dots — only non-zero counts */}
            {permCount > 0 && (
              <StatusDot color={STATUS_COLORS["waiting_permission"]} count={permCount} />
            )}
            {attnCount > 0 && (
              <StatusDot color={STATUS_COLORS["waiting_input"]} count={attnCount} />
            )}
            {workCount > 0 && (
              <StatusDot color={STATUS_COLORS["working"]} count={workCount} />
            )}
            {idleCount > 0 && permCount === 0 && attnCount === 0 && workCount === 0 && (
              <StatusDot color={STATUS_COLORS["idle"]} count={idleCount} />
            )}
          </box>
        );
      })}
    </window>
  );
}

// ---------------------------------------------------------------------------
// Application entry point
// ---------------------------------------------------------------------------

const cssPath = GLib.build_filenamev([
  GLib.get_home_dir(),
  ".config",
  "ags",
  "lcctop",
  "style.css",
]);

App.start({
  css: cssPath,
  main() {
    startPolling();
    LcctopPickerWindow();
    LcctopBarWindow();
  },
  requestHandler(request: string, res: (response: string) => void) {
    switch (request) {
      case "toggle lcctop-picker":
        App.toggle_window("lcctop-picker");
        res("ok");
        break;
      case "toggle lcctop-bar":
        App.toggle_window("lcctop-bar");
        res("ok");
        break;
      default:
        res(`unknown request: ${request}`);
    }
  },
});
