import { Session } from "../lib/types.js";

interface SessionCardProps {
  session: Session;
  selected: boolean;
  onActivate: () => void;
}

/**
 * Renders a single session card matching cctop's two-row layout:
 *
 *   ▍  project-name  3 agents  CC         Permission
 *      main  /  Allow Bash: npm test          just now
 *
 * - Left accent bar: full card height, colored by status
 * - Row 1 left: name (bold), agent count (no brackets), source badge
 * - Right column: status label (top, colored) + time (bottom, gray)
 * - Row 2: branch / context (gray, indented past accent bar)
 */
export default function SessionCard({ session, selected, onActivate }: SessionCardProps) {
  const s = session;

  // Source badge color: CC = amber, OC/CX = blue — text only, no background
  const sourceBadgeColor =
    s.sourceLabel === "OC" || s.sourceLabel === "CX" ? "#89b4fa" : "#f9e2af";

  // Subagent label (purple) — no brackets, matches cctop screenshot
  const agentLabel =
    s.subagentCount > 0
      ? `${s.subagentCount} agent${s.subagentCount === 1 ? "" : "s"}`
      : "";

  // Second line: branch / context
  const secondLine =
    s.contextLine ? `${s.branch}  /  ${s.contextLine}` : s.branch;

  return (
    <button
      cssClasses={["session-card", selected ? "selected" : ""]}
      onClicked={onActivate}
    >
      {/* Outer hbox: [accent-bar] [content-vbox] [right-vbox] */}
      <box orientation={0} spacing={0}>

        {/* Left accent bar — expands to full card height */}
        <box
          cssClasses={["accent-bar"]}
          css={`background-color: ${s.statusColor}; min-width: 4px;`}
          vexpand={true}
        />

        {/* Content: row1 (name/agents/source) + row2 (branch/context) */}
        <box orientation={1} spacing={3} hexpand={true} css="padding: 6px 8px 6px 8px;">
          {/* Row 1 */}
          <box orientation={0} spacing={6}>
            <label
              label={s.displayName}
              cssClasses={["card-name"]}
              xalign={0}
            />
            {agentLabel !== "" && (
              <label
                label={agentLabel}
                cssClasses={["card-agents"]}
              />
            )}
            <label
              label={s.sourceLabel}
              cssClasses={["card-source"]}
              css={`color: ${sourceBadgeColor};`}
            />
          </box>
          {/* Row 2: branch / context */}
          <label
            label={secondLine}
            cssClasses={["card-context"]}
            xalign={0}
            ellipsize={3 /* END */}
            maxWidthChars={80}
          />
        </box>

        {/* Right column: status (top) + time (bottom), right-aligned */}
        <box orientation={1} spacing={2} css="padding: 6px 10px 6px 0; min-width: 80px;" valign={3 /* CENTER */}>
          <label
            label={s.statusLabel}
            cssClasses={["card-status"]}
            css={`color: ${s.statusColor};`}
            xalign={1}
          />
          <label
            label={s.relativeTime}
            cssClasses={["card-time"]}
            xalign={1}
          />
        </box>

      </box>
    </button>
  );
}
