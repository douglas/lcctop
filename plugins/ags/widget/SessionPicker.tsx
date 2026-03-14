import { createState, createEffect } from "ags";
import App from "ags/gtk4/app";
import { Session, STATUS_COLORS } from "../lib/types.js";
import { sessions } from "../lib/sessions.js";
import { focusSession } from "../lib/focus.js";
import SessionCard from "./SessionCard.js";
import StatusDot from "./StatusDot.js";

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

function PickerHeader({ sessionList }: { sessionList: Session[] }) {
  const permCount = sessionList.filter((s) => s.status === "waiting_permission").length;
  const attnCount = sessionList.filter(
    (s) => s.status === "waiting_input" || s.status === "needs_attention",
  ).length;
  const workCount = sessionList.filter(
    (s) => s.status === "working" || s.status === "compacting",
  ).length;
  const idleCount = sessionList.filter((s) => s.status === "idle").length;

  return (
    <box orientation={0} spacing={8} cssClasses={["picker-header"]} css="padding: 8px 12px;">
      <label
        label="  lcctop"
        cssClasses={["header-title"]}
        css="font-weight: bold; color: #cdd6f4; font-size: 1em;"
      />
      <box hexpand={true} />
      <StatusDot color={STATUS_COLORS["waiting_permission"]} count={permCount} />
      <StatusDot color={STATUS_COLORS["waiting_input"]} count={attnCount} />
      <StatusDot color={STATUS_COLORS["working"]} count={workCount} />
      <StatusDot color={STATUS_COLORS["idle"]} count={idleCount} />
    </box>
  );
}

// ---------------------------------------------------------------------------
// Footer
// ---------------------------------------------------------------------------

function PickerFooter() {
  return (
    <box
      orientation={0}
      spacing={16}
      cssClasses={["picker-footer"]}
      css="padding: 6px 12px;"
    >
      <label label="j/↓ next" css="color: #6c7086; font-size: 0.78em;" />
      <label label="k/↑ prev" css="color: #6c7086; font-size: 0.78em;" />
      <label label="enter focus" css="color: #6c7086; font-size: 0.78em;" />
      <label label="q/esc cancel" css="color: #6c7086; font-size: 0.78em;" />
    </box>
  );
}

// ---------------------------------------------------------------------------
// Main SessionPicker
// ---------------------------------------------------------------------------

/** Return the initial selected index: first session needing attention, else 0. */
function initialSelection(list: Session[]): number {
  const urgentIdx = list.findIndex(
    (s) =>
      s.status === "waiting_permission" ||
      s.status === "waiting_input" ||
      s.status === "needs_attention",
  );
  return urgentIdx >= 0 ? urgentIdx : 0;
}

export default function SessionPicker() {
  const [selectedIndex, setSelectedIndex] = createState(initialSelection(sessions.peek()));

  // Keep selection in bounds when session list changes
  createEffect(() => {
    const list = sessions();
    const cur = selectedIndex.peek();
    if (cur >= list.length) {
      setSelectedIndex(Math.max(0, list.length - 1));
    }
  });

  function close() {
    App.toggle_window("lcctop-picker");
  }

  function activateSelected() {
    const list = sessions.peek();
    const idx = selectedIndex.peek();
    const session = list[idx];
    if (session) {
      focusSession(session);
    }
    close();
  }

  function moveSelection(delta: number) {
    const list = sessions.peek();
    if (!list.length) return;
    const next = (selectedIndex.peek() + delta + list.length) % list.length;
    setSelectedIndex(next);
  }

  // Key handler returns true to stop propagation
  function handleKey(_widget: unknown, keyval: number): boolean {
    // Gdk key constants
    const GDK_KEY = {
      j: 106,
      k: 107,
      q: 113,
      Return: 65293,
      KP_Enter: 65421,
      Escape: 65307,
      Down: 65364,
      Up: 65362,
    } as const;

    switch (keyval) {
      case GDK_KEY.j:
      case GDK_KEY.Down:
        moveSelection(1);
        return true;
      case GDK_KEY.k:
      case GDK_KEY.Up:
        moveSelection(-1);
        return true;
      case GDK_KEY.Return:
      case GDK_KEY.KP_Enter:
        activateSelected();
        return true;
      case GDK_KEY.Escape:
      case GDK_KEY.q:
        close();
        return true;
      default:
        return false;
    }
  }

  return (
    <box
      orientation={1 /* VERTICAL */}
      spacing={0}
      cssClasses={["session-picker"]}
      onKeyPressed={handleKey}
      canFocus={true}
    >
      {/* Header */}
      {sessions.as((list) => (
        <PickerHeader sessionList={list} />
      ))}

      {/* Separator */}
      <box css="min-height: 1px; background-color: #45475a;" />

      {/* Scrollable session list */}
      <scrolledwindow
        hscrollbarPolicy={2 /* NEVER */}
        vscrollbarPolicy={1 /* AUTOMATIC */}
        vexpand={true}
        cssClasses={["picker-scroll"]}
      >
        <box orientation={1} spacing={0}>
          {sessions.as((list) => {
            if (!list.length) {
              return (
                <box css="padding: 32px; min-height: 120px;">
                  <label
                    label="No active sessions"
                    css="color: #6c7086; font-size: 0.9em;"
                    halign={3 /* CENTER */}
                    valign={3 /* CENTER */}
                    hexpand={true}
                  />
                </box>
              );
            }
            return list.map((session, i) => (
              <box key={session.session_id} orientation={1} spacing={0}>
                {selectedIndex.as((sel) => (
                  <SessionCard
                    session={session}
                    selected={sel === i}
                    onActivate={() => {
                      setSelectedIndex(i);
                      activateSelected();
                    }}
                  />
                ))}
                {i < list.length - 1 && (
                  <box css="min-height: 1px; background-color: #313244; margin: 0 8px;" />
                )}
              </box>
            ));
          })}
        </box>
      </scrolledwindow>

      {/* Separator */}
      <box css="min-height: 1px; background-color: #45475a;" />

      {/* Footer */}
      <PickerFooter />
    </box>
  );
}
