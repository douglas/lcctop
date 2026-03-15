import GLib from "gi://GLib";
import Gio from "gi://Gio";
// @ts-ignore - no type stubs for Gtk4 in this project
import Gtk from "gi://Gtk?version=4.0";
import App from "ags/gtk4/app";
import Astal from "gi://Astal?version=4.0";
import { With } from "ags";
import StatusDot from "./widget/StatusDot.js";
import { sessions } from "./lib/sessions.js";
import { STATUS_COLORS } from "./lib/types.js";

// ---------------------------------------------------------------------------
// Small bottom-right bar showing session status dots.
// Click launches the Tauri session picker (lcctop-panel).
// ---------------------------------------------------------------------------

function LcctopBarWindow() {
  return (
    <window
      application={App}
      name="lcctop-bar"
      namespace="lcctop-bar"
      cssClasses={["lcctop-bar-window"]}
      layer={Astal.Layer.TOP}
      anchor={Astal.WindowAnchor.BOTTOM | Astal.WindowAnchor.RIGHT}
      exclusivity={Astal.Exclusivity.EXCLUSIVE}
      keymode={Astal.Keymode.NONE}
      visible={true}
      onRealize={(win: unknown) => {
        const clickCtrl = new Gtk.GestureClick();
        clickCtrl.connect("pressed", () => {
          // Use lcctop-pick until lcctop-panel (Tauri) is built and installed
          try {
            Gio.Subprocess.new(["lcctop-pick"], Gio.SubprocessFlags.NONE);
          } catch (e) {
            console.error("lcctop-pick failed:", e);
          }
        });
        (win as { add_controller(c: unknown): void }).add_controller(clickCtrl);
      }}
    >
      <box>
        <With value={sessions}>
          {(list) => {
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
              return <box css="min-width: 1px; min-height: 1px;" />;
            }

            const iconColor =
              permCount > 0 ? STATUS_COLORS["waiting_permission"] :
              attnCount > 0 ? STATUS_COLORS["waiting_input"] :
              workCount > 0 ? STATUS_COLORS["working"] :
              STATUS_COLORS["idle"];

            return (
              <box
                orientation={0}
                spacing={6}
                cssClasses={["bar-widget"]}
                css="padding: 4px 8px; background-color: #1e1e2e; border-radius: 6px; margin: 4px;"
              >
                <label label="󰚩" css={`color: ${iconColor}; font-size: 1em;`} />
                {totalCount > 1 && (
                  <label label={String(totalCount)} css="color: #cdd6f4; font-size: 0.85em;" />
                )}
                {permCount > 0 && <StatusDot color={STATUS_COLORS["waiting_permission"]} count={permCount} />}
                {attnCount > 0 && <StatusDot color={STATUS_COLORS["waiting_input"]} count={attnCount} />}
                {workCount > 0 && <StatusDot color={STATUS_COLORS["working"]} count={workCount} />}
                {idleCount > 0 && permCount === 0 && attnCount === 0 && workCount === 0 && (
                  <StatusDot color={STATUS_COLORS["idle"]} count={idleCount} />
                )}
              </box>
            );
          }}
        </With>
      </box>
    </window>
  );
}

// ---------------------------------------------------------------------------
// Application entry point
// ---------------------------------------------------------------------------

const installedCss = GLib.build_filenamev([GLib.get_home_dir(), ".config", "ags", "lcctop", "style.css"]);
const sourceCss = GLib.build_filenamev([GLib.get_current_dir(), "style.css"]);
const cssPath = GLib.file_test(installedCss, GLib.FileTest.EXISTS) ? installedCss : sourceCss;

App.start({
  css: cssPath,
  main() {
    LcctopBarWindow();
  },
});
