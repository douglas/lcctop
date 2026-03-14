/**
 * lcctop opencode plugin
 *
 * Subscribes to opencode bus events and writes session state to
 * ~/.cctop/sessions/{pid}.json so lcctop-waybar can display them.
 *
 * Install:
 *   rake install_opencode
 *   # then add "file://~/.config/opencode/plugins/cctop.js" to the
 *   # "plugin" array in opencode.json
 */

import { join } from "path";
import { homedir } from "os";
import { mkdirSync, writeFileSync, renameSync, unlinkSync } from "fs";

const SESSIONS_DIR = join(homedir(), ".cctop", "sessions");

// --- helpers ---

function now() {
  return new Date().toISOString();
}

function ensureDir(dir) {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
}

function sessionPath(pid) {
  return join(SESSIONS_DIR, `${pid}.json`);
}

function writeSession(state) {
  ensureDir(SESSIONS_DIR);
  const path = sessionPath(state.pid);
  const tmp = `${path}.${process.pid}.tmp`;
  const data = JSON.stringify(state, null, 2);
  writeFileSync(tmp, data, { mode: 0o600 });
  renameSync(tmp, path);
}

function removeSession(pid) {
  try { unlinkSync(sessionPath(pid)); } catch { /* already gone */ }
}

// --- session registry ---
// Keyed by opencode session ID → session state
const sessions = new Map();

function getOrCreate(sessionId, projectPath) {
  if (!sessions.has(sessionId)) {
    sessions.set(sessionId, {
      session_id:    sessionId,
      project_path:  projectPath || "",
      project_name:  projectPath ? projectPath.split("/").pop() : "",
      branch:        "unknown",
      status:        "idle",
      last_activity: now(),
      started_at:    now(),
      pid:           process.pid,
      pid_start_time: null,
      source:        "opencode",
    });
  }
  return sessions.get(sessionId);
}

function flush(state) {
  writeSession(state);
}

// --- event handlers ---

function onSessionCreated(event) {
  const state = getOrCreate(event.sessionId, event.projectPath);
  state.status        = "idle";
  state.last_activity = now();
  if (event.branch) state.branch = event.branch;
  flush(state);
}

function onSessionIdle(event) {
  const state = sessions.get(event.sessionId);
  if (!state) return;
  state.status        = "idle";
  state.last_activity = now();
  state.last_tool     = null;
  state.last_tool_detail = null;
  flush(state);
}

function onToolBefore(event) {
  const state = sessions.get(event.sessionId);
  if (!state) return;
  state.status           = "working";
  state.last_activity    = now();
  state.last_tool        = event.tool;
  state.last_tool_detail = event.input ? JSON.stringify(event.input).slice(0, 120) : null;
  flush(state);
}

function onToolAfter(event) {
  const state = sessions.get(event.sessionId);
  if (!state) return;
  state.last_activity = now();
  // stay working until idle event confirms completion
  flush(state);
}

function onPermissionAsk(event) {
  const state = sessions.get(event.sessionId);
  if (!state) return;
  state.status               = "waiting_permission";
  state.last_activity        = now();
  state.notification_message = event.message || "Permission needed";
  flush(state);
}

function onUserPrompt(event) {
  const state = sessions.get(event.sessionId);
  if (!state) return;
  state.status        = "waiting_input";
  state.last_activity = now();
  state.last_prompt   = event.prompt ? event.prompt.slice(0, 36) : null;
  flush(state);
}

function onSessionEnd(event) {
  const state = sessions.get(event.sessionId);
  if (state) {
    removeSession(state.pid);
    sessions.delete(event.sessionId);
  }
}

// --- plugin export ---

export default function plugin(bus) {
  bus.on("session.created",          onSessionCreated);
  bus.on("session.idle",             onSessionIdle);
  bus.on("session.end",              onSessionEnd);
  bus.on("tool.execute.before",      onToolBefore);
  bus.on("tool.execute.after",       onToolAfter);
  bus.on("permission.ask",           onPermissionAsk);
  bus.on("user.prompt",              onUserPrompt);
}
