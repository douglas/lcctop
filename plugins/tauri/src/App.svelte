<script lang="ts">
  import { onMount, onDestroy } from "svelte";
  import { invoke } from "@tauri-apps/api/core";
  import SessionCard from "./SessionCard.svelte";
  import {
    fetchSessions,
    setupSessionsListener,
    findDefaultSelection,
    countByStatus,
  } from "./lib/sessions";
  import type { DisplaySession } from "./lib/types";

  // ── State ────────────────────────────────────────────────────────────────

  let sessions = $state<DisplaySession[]>([]);
  let selectedIndex = $state(0);
  let listEl = $state<HTMLElement | undefined>(undefined);
  let unlisten: (() => void) | null = null;

  // ── Derived ──────────────────────────────────────────────────────────────

  const statusCounts = $derived(countByStatus(sessions));

  const selectedSession = $derived(sessions[selectedIndex] ?? null);

  // Status dot definitions (only render non-zero counts)
  const dotDefs = $derived(() => {
    const defs = [
      { color: "#f38ba8", count: statusCounts.permission, key: "permission" },
      { color: "#f9e2af", count: statusCounts.attention,  key: "attention"  },
      { color: "#a6e3a1", count: statusCounts.working,    key: "working"    },
      { color: "#89b4fa", count: statusCounts.compacting, key: "compacting" },
      { color: "#6c7086", count: statusCounts.idle,       key: "idle"       },
    ];
    return defs.filter((d) => d.count > 0);
  });

  // ── Data loading ─────────────────────────────────────────────────────────

  async function loadSessions() {
    try {
      const loaded = await fetchSessions();
      sessions = loaded;
      selectedIndex = findDefaultSelection(loaded);
    } catch (err) {
      console.error("Failed to load sessions:", err);
      sessions = [];
      selectedIndex = 0;
    }
  }

  // ── Keyboard handling ────────────────────────────────────────────────────

  function handleKeydown(e: KeyboardEvent) {
    if (sessions.length === 0) {
      if (e.key === "Escape" || e.key === "q") hideWindow();
      return;
    }

    switch (e.key) {
      case "j":
      case "ArrowDown":
        e.preventDefault();
        selectedIndex = Math.min(selectedIndex + 1, sessions.length - 1);
        scrollSelectedIntoView();
        break;

      case "k":
      case "ArrowUp":
        e.preventDefault();
        selectedIndex = Math.max(selectedIndex - 1, 0);
        scrollSelectedIntoView();
        break;

      case "Enter":
        e.preventDefault();
        if (selectedSession) {
          focusSession(selectedSession.pid);
        }
        break;

      case "Escape":
      case "q":
        e.preventDefault();
        hideWindow();
        break;
    }
  }

  function scrollSelectedIntoView() {
    // Let DOM update, then scroll
    requestAnimationFrame(() => {
      if (!listEl) return;
      const cards = listEl.querySelectorAll<HTMLElement>(".session-card");
      const card = cards[selectedIndex];
      if (card) {
        card.scrollIntoView({ block: "nearest", behavior: "smooth" });
      }
    });
  }

  async function focusSession(pid: number) {
    try {
      await invoke("focus_session", { pid });
    } catch (err) {
      console.error("focus_session failed:", err);
    }
    await hideWindow();
  }

  async function hideWindow() {
    try {
      await invoke("hide_window");
    } catch (err) {
      console.error("hide_window failed:", err);
    }
  }

  // ── Lifecycle ────────────────────────────────────────────────────────────

  onMount(async () => {
    await loadSessions();
    unlisten = await setupSessionsListener(loadSessions);
    window.addEventListener("keydown", handleKeydown);
  });

  onDestroy(() => {
    window.removeEventListener("keydown", handleKeydown);
    unlisten?.();
  });
</script>

<div class="panel">
  <!-- Header -->
  <header class="panel-header">
    <span class="panel-title">lcctop</span>
    <div class="status-dots">
      {#each dotDefs() as dot (dot.key)}
        <span class="status-dot" style="color: {dot.color}">
          <span class="dot">●</span>
          <span>{dot.count}</span>
        </span>
      {/each}
    </div>
  </header>

  <!-- Session list -->
  <div class="session-list" bind:this={listEl}>
    {#if sessions.length === 0}
      <div class="empty-state">No active sessions</div>
    {:else}
      {#each sessions as session, i (session.session_id + session.pid)}
        <SessionCard
          {session}
          selected={i === selectedIndex}
        />
      {/each}
    {/if}
  </div>

  <!-- Footer -->
  <footer class="panel-footer">
    <span class="kbd-hint">
      <span>j/↓ next</span>
      <span class="kbd-sep">·</span>
      <span>k/↑ prev</span>
      <span class="kbd-sep">·</span>
      <span>enter focus</span>
      <span class="kbd-sep">·</span>
      <span>q/esc cancel</span>
    </span>
  </footer>
</div>
