<script lang="ts">
  import type { DisplaySession } from "./lib/types";

  interface Props {
    session: DisplaySession;
    selected: boolean;
  }

  let { session, selected }: Props = $props();

  const sourceBadgeColor = $derived(
    session.sourceLabel === "OC" ? "#89b4fa" : "#f9e2af"
  );

  const subagentColor = "#cba6f7";
</script>

<div class="session-card" class:selected aria-selected={selected}>
  <!-- Left accent bar -->
  <div class="accent-bar" style="background: {session.statusColor}"></div>

  <!-- Card body -->
  <div class="card-body">
    <!-- Line 1: name, subagents, source badge, status, time -->
    <div class="card-line card-line-top">
      <span class="project-name">{session.displayName}</span>

      {#if session.subagentCount > 0}
        <span class="subagent-badge" style="color: {subagentColor}">
          [{session.subagentCount}]
        </span>
      {/if}

      <span
        class="source-badge"
        style="color: {sourceBadgeColor}"
      >{session.sourceLabel}</span>

      <span class="status-label" style="color: {session.statusColor}">
        {session.statusLabel}
      </span>

      <span class="spacer"></span>

      <span class="rel-time">{session.relativeTime}</span>
    </div>

    <!-- Line 2: branch / context -->
    <div class="card-line card-line-bottom">
      <span class="branch">{session.branch}</span>

      {#if session.contextLine}
        <span class="sep"> / </span>
        <span class="context-line">{session.contextLine}</span>
      {/if}
    </div>
  </div>
</div>

<style>
  .session-card {
    display: flex;
    align-items: stretch;
    border-bottom: 1px solid rgba(69, 71, 90, 0.25);
    transition: background 80ms ease;
    cursor: default;
  }

  .session-card:last-child {
    border-bottom: none;
  }

  .session-card.selected {
    background: #313244; /* --surface0 */
  }

  .session-card:not(.selected):hover {
    background: rgba(49, 50, 68, 0.5);
  }

  /* ── Accent bar ──────────────────────────────────────────────────────────── */

  .accent-bar {
    width: 4px;
    flex-shrink: 0;
    border-radius: 0;
  }

  /* ── Card body ───────────────────────────────────────────────────────────── */

  .card-body {
    flex: 1;
    min-width: 0;
    padding: 7px 12px 6px 10px;
    display: flex;
    flex-direction: column;
    gap: 3px;
  }

  /* ── Line 1 ──────────────────────────────────────────────────────────────── */

  .card-line {
    display: flex;
    align-items: baseline;
    gap: 5px;
    min-width: 0;
    white-space: nowrap;
    overflow: hidden;
  }

  .project-name {
    font-weight: 700;
    color: #cdd6f4; /* --text */
    overflow: hidden;
    text-overflow: ellipsis;
    flex-shrink: 1;
    min-width: 0;
    max-width: 160px;
  }

  .subagent-badge {
    font-size: 11px;
    font-weight: 600;
    flex-shrink: 0;
  }

  .source-badge {
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 0.04em;
    border: 1px solid currentColor;
    border-radius: 3px;
    padding: 0 3px;
    line-height: 1.4;
    flex-shrink: 0;
    opacity: 0.9;
  }

  .status-label {
    font-size: 11px;
    font-weight: 600;
    flex-shrink: 0;
  }

  .spacer {
    flex: 1;
  }

  .rel-time {
    font-size: 11px;
    color: #7f849c; /* --overlay1 */
    flex-shrink: 0;
    text-align: right;
  }

  /* ── Line 2 ──────────────────────────────────────────────────────────────── */

  .card-line-bottom {
    font-size: 11px;
    color: #a6adc8; /* --subtext */
    overflow: hidden;
  }

  .branch {
    color: #6c7086; /* --gray */
    flex-shrink: 0;
  }

  .sep {
    color: #45475a; /* --surface1 */
    flex-shrink: 0;
  }

  .context-line {
    overflow: hidden;
    text-overflow: ellipsis;
    flex: 1;
    min-width: 0;
  }
</style>
