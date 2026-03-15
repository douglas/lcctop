import GLib from "gi://GLib";
// @ts-ignore - no type stubs for Gtk4 in this project
import Gtk from "gi://Gtk?version=4.0";
import App from "ags/gtk4/app";
import Astal from "gi://Astal?version=4.0";
import { createState, createEffect, With } from "ags";
import SessionPicker from "./widget/SessionPicker.js";
import StatusDot from "./widget/StatusDot.js";
import { sessions } from "./lib/sessions.js";
import { focusSession } from "./lib/focus.js";
import { Session, STATUS_COLORS } from "./lib/types.js";

// ---------------------------------------------------------------------------
// Floating session picker window (700×450, layer=TOP, centered)
// Key events handled at window level — GtkBox has no key-pressed signal
// ---------------------------------------------------------------------------

function initialSelection(list: Session[]): number {
  const idx = list.findIndex(
    (s) =>
      s.status === "waiting_permission" ||
      s.status === "waiting_input" ||
      s.status === "needs_attention",
  );
  return idx >= 0 ? idx : 0;
}

function LcctopPickerWindow() {
  const [selectedIndex, setSelectedIndex] = createState(initialSelection(sessions.peek()));

  createEffect(() => {
    const list = sessions();
    if (selectedIndex.peek() >= list.length) {
      setSelectedIndex(Math.max(0, list.length - 1));
    }
  });

  function close() {
    App.toggle_window("lcctop-picker");
  }

  function activateSelected() {
    const list = sessions.peek();
    const session = list[selectedIndex.peek()];
    if (session) focusSession(session);
    close();
  }

  function moveSelection(delta: number) {
    const list = sessions.peek();
    if (!list.length) return;
    setSelectedIndex((selectedIndex.peek() + delta + list.length) % list.length);
  }

  function attachControllers(win: unknown) {
    const w = win as { add_controller(c: unknown): void };

    // CAPTURE phase: window intercepts key events before any child widget
    // (GtkButtons etc.) gets a chance to process them.
    // Astal.Keymode.EXCLUSIVE has the compositor grant keyboard focus to this
    // surface; CAPTURE ensures GTK routes events here first.
    // NOTE: do NOT call grab_focus() in notify::visible — that fires before the
    // window is mapped, which corrupts GTK's focus state ("Broken accounting").
    const keyCtrl = new Gtk.EventControllerKey();
    (keyCtrl as any).propagation_phase = 1; // GTK_PHASE_CAPTURE
    keyCtrl.connect("key-pressed", (_c: unknown, keyval: number) => handleKey(null, keyval));
    w.add_controller(keyCtrl);

    // Click-to-close scrim via GestureClick
    const clickCtrl = new Gtk.GestureClick();
    clickCtrl.connect("pressed", close);
    w.add_controller(clickCtrl);
  }

  function handleKey(_widget: unknown, keyval: number): boolean {
    const GDK_KEY = {
      j: 106, k: 107, q: 113,
      Return: 65293, KP_Enter: 65421,
      Escape: 65307, Down: 65364, Up: 65362,
    } as const;

    switch (keyval) {
      case GDK_KEY.j: case GDK_KEY.Down: moveSelection(1); return true;
      case GDK_KEY.k: case GDK_KEY.Up:   moveSelection(-1); return true;
      case GDK_KEY.Return: case GDK_KEY.KP_Enter: activateSelected(); return true;
      case GDK_KEY.Escape: case GDK_KEY.q: close(); return true;
      default: return false;
    }
  }

  return (
    <window
      application={App}
      name="lcctop-picker"
      namespace="lcctop-picker"
      cssClasses={["lcctop-picker-window"]}
      layer={Astal.Layer.TOP}
      anchor={
        Astal.WindowAnchor.TOP |
        Astal.WindowAnchor.BOTTOM |
        Astal.WindowAnchor.LEFT |
        Astal.WindowAnchor.RIGHT
      }
      exclusivity={Astal.Exclusivity.IGNORE}
      keymode={Astal.Keymode.EXCLUSIVE}
      visible={false}
      onRealize={attachControllers}
    >
      {/* Transparent scrim — click outside picker to close */}
      <box
        cssClasses={["picker-scrim"]}
        hexpand={true}
        vexpand={true}
        css="background-color: rgba(0,0,0,0.4);"
        halign={3 /* CENTER */}
        valign={3 /* CENTER */}
      >
        {/* Picker card */}
        <box
          cssClasses={["picker-container"]}
          css="min-width: 700px; min-height: 450px;"
          halign={3 /* CENTER */}
          valign={3 /* CENTER */}
        >
          <SessionPicker
            selectedIndex={selectedIndex}
            setSelectedIndex={setSelectedIndex}
            onActivate={activateSelected}
            onClose={close}
          />
        </box>
      </box>
    </window>
  );
}

// ---------------------------------------------------------------------------
// Small bar widget (bottom-right) showing session status dots
// Click toggles the AGS session picker
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
        clickCtrl.connect("pressed", () => App.toggle_window("lcctop-picker"));
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
    LcctopPickerWindow();
    LcctopBarWindow();
  },
  requestHandler(args: string[], res: (response: string) => void) {
    const request = args[0] ?? "";
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
        res(request ? `unknown request: ${request}` : "ok");
    }
  },
});
