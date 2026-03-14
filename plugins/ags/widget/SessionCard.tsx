import { Session } from "../lib/types.js";

interface SessionCardProps {
  session: Session;
  selected: boolean;
  onActivate: () => void;
}

/**
 * Renders a single session card with:
 * - Left accent bar colored by status
 * - Name (bold), subagent count (purple), source badge, status label, relative time
 * - Second line: branch / context
 */
export default function SessionCard({ session, selected, onActivate }: SessionCardProps) {
  const s = session;
  const bgCss = selected ? "background-color: #313244;" : "";

  // Source badge color: CC = amber, OC = blue
  const sourceBadgeColor = s.sourceLabel === "OC" ? "#89b4fa" : "#f9e2af";

  // Subagent label (purple) — only shown when > 0
  const agentLabel =
    s.subagentCount > 0
      ? `[${s.subagentCount} agent${s.subagentCount === 1 ? "" : "s"}]`
      : "";

  // Second line: branch / context
  const secondLine =
    s.contextLine ? `${s.branch}  /  ${s.contextLine}` : s.branch;

  return (
    <button
      cssClasses={["session-card", selected ? "selected" : ""]}
      css={bgCss}
      onClicked={onActivate}
    >
      <box orientation={1 /* VERTICAL */} spacing={0}>
        {/* Row 1: accent bar + name + badges + status + time */}
        <box orientation={0 /* HORIZONTAL */} spacing={0} cssClasses={["card-row1"]}>
          {/* Left accent bar */}
          <box
            cssClasses={["accent-bar"]}
            css={`background-color: ${s.statusColor}; min-width: 3px; min-height: 36px;`}
          />
          <box
            orientation={0}
            spacing={6}
            hexpand={true}
            css="padding: 4px 8px 2px 8px;"
          >
            {/* Project name */}
            <label
              label={s.displayName}
              cssClasses={["card-name"]}
              xalign={0}
              css="font-weight: bold;"
            />

            {/* Agent count (purple) */}
            {agentLabel !== "" && (
              <label
                label={agentLabel}
                cssClasses={["card-agents"]}
                css="color: #cba6f7; font-size: 0.85em;"
              />
            )}

            {/* Source badge */}
            <label
              label={s.sourceLabel}
              cssClasses={["card-source"]}
              css={`color: ${sourceBadgeColor}; font-size: 0.8em; font-weight: bold;`}
            />

            {/* Spacer */}
            <box hexpand={true} />

            {/* Status label */}
            <label
              label={s.statusLabel}
              cssClasses={["card-status"]}
              css={`color: ${s.statusColor}; font-size: 0.85em;`}
            />

            {/* Relative time */}
            <label
              label={s.relativeTime}
              cssClasses={["card-time"]}
              css="color: #6c7086; font-size: 0.8em; margin-left: 8px;"
            />
          </box>
        </box>

        {/* Row 2: branch / context */}
        <box orientation={0} css="padding: 0 8px 4px 19px;">
          <label
            label={secondLine}
            cssClasses={["card-context"]}
            css="color: #a6adc8; font-size: 0.82em;"
            xalign={0}
            ellipsize={3 /* END */}
            maxWidthChars={80}
          />
        </box>
      </box>
    </button>
  );
}
