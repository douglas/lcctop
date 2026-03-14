import { Accessor, With, For } from "ags";
import { Session, STATUS_COLORS } from "../lib/types.js";
import { sessions } from "../lib/sessions.js";
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
    <box orientation={0} spacing={16} cssClasses={["picker-footer"]} css="padding: 6px 12px;">
      <label label="j/↓ next"    css="color: #6c7086; font-size: 0.78em;" />
      <label label="k/↑ prev"    css="color: #6c7086; font-size: 0.78em;" />
      <label label="enter focus"  css="color: #6c7086; font-size: 0.78em;" />
      <label label="q/esc cancel" css="color: #6c7086; font-size: 0.78em;" />
    </box>
  );
}

// ---------------------------------------------------------------------------
// Main SessionPicker
// ---------------------------------------------------------------------------

interface SessionPickerProps {
  selectedIndex: Accessor<number>;
  setSelectedIndex: (n: number) => void;
  onActivate: () => void;
  onClose: () => void;
}

export default function SessionPicker({
  selectedIndex,
  setSelectedIndex,
  onActivate,
}: SessionPickerProps) {
  return (
    <box orientation={1 /* VERTICAL */} spacing={0} cssClasses={["session-picker"]}>
      {/* Header — rebuilt reactively when sessions change */}
      <With value={sessions}>
        {(list) => <PickerHeader sessionList={list} />}
      </With>

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
          <With value={sessions}>
            {(list) => {
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
              return (
                <box orientation={1} spacing={0}>
                  <For each={sessions} id={(s) => s.session_id}>
                    {(session, idxAcc) => (
                      <box orientation={1} spacing={0}>
                        <With value={selectedIndex}>
                          {(sel) => (
                            <SessionCard
                              session={session}
                              selected={sel === idxAcc.peek()}
                              onActivate={() => {
                                setSelectedIndex(idxAcc.peek());
                                onActivate();
                              }}
                            />
                          )}
                        </With>
                      </box>
                    )}
                  </For>
                </box>
              );
            }}
          </With>
        </box>
      </scrolledwindow>

      {/* Separator */}
      <box css="min-height: 1px; background-color: #45475a;" />

      {/* Footer */}
      <PickerFooter />
    </box>
  );
}
