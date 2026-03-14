/**
 * lcctop opencode plugin
 *
 * Writes session state to ~/.cctop/sessions/{pid}.json so lcctop-waybar
 * can display opencode sessions in the Waybar tooltip.
 *
 * Install:
 *   rake install_opencode
 *   Then add "file://~/.config/opencode/plugins/cctop.js" to the
 *   "plugin" array in opencode.json
 */

import { join } from "path";
import { homedir } from "os";
import { mkdirSync, writeFileSync, renameSync, unlinkSync } from "fs";
import { execFileSync } from "child_process";

const SESSIONS_DIR = join(homedir(), ".cctop", "sessions");

// --- helpers ---

function nowISO() {
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
  writeFileSync(tmp, JSON.stringify(state, null, 2), { mode: 0o600 });
  renameSync(tmp, path);
}

function removeSession(pid) {
  try { unlinkSync(sessionPath(pid)); } catch { /* already gone */ }
}

function getBranch(directory) {
  try {
    return execFileSync("git", ["rev-parse", "--abbrev-ref", "HEAD"], {
      cwd: directory,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return "unknown";
  }
}

// --- session registry ---
// Keyed by opencode session ID → lcctop state object
const sessions = new Map();

function getOrCreate(sessionID, directory) {
  if (!sessions.has(sessionID)) {
    sessions.set(sessionID, {
      session_id:    sessionID,
      project_path:  directory || "",
      project_name:  directory ? directory.split("/").pop() : "",
      branch:        getBranch(directory),
      status:        "idle",
      last_activity: nowISO(),
      started_at:    nowISO(),
      pid:           process.pid,
      pid_start_time: null,
      source:        "opencode",
    });
  }
  return sessions.get(sessionID);
}

// --- plugin export ---
// The opencode plugin API: a named async export that receives context
// and returns a Hooks object with lifecycle callbacks.

export const CctopPlugin = async ({ directory }) => {
  return {
    // General event handler — receives all opencode events.
    event: async ({ event }) => {
      switch (event.type) {
        case "session.created": {
          const info = event.properties.info;
          const s = getOrCreate(info.id, info.directory || directory);
          s.status = "idle";
          s.last_activity = nowISO();
          writeSession(s);
          break;
        }

        case "session.idle": {
          const s = sessions.get(event.properties.sessionID);
          if (!s) return;
          s.status = "idle";
          s.last_activity = nowISO();
          s.last_tool = null;
          s.last_tool_detail = null;
          writeSession(s);
          break;
        }

        case "session.status": {
          const { sessionID, status } = event.properties;
          const s = sessions.get(sessionID);
          if (!s) return;
          if (status.type === "busy") s.status = "working";
          else if (status.type === "idle") s.status = "idle";
          s.last_activity = nowISO();
          writeSession(s);
          break;
        }

        case "session.deleted": {
          const info = event.properties.info;
          const s = sessions.get(info.id);
          if (s) {
            removeSession(s.pid);
            sessions.delete(info.id);
          }
          break;
        }

        case "permission.updated": {
          const perm = event.properties;
          const s = sessions.get(perm.sessionID);
          if (!s) return;
          s.status = "waiting_permission";
          s.last_activity = nowISO();
          s.notification_message = perm.title || "Permission needed";
          writeSession(s);
          break;
        }

        case "vcs.branch.updated": {
          const branch = event.properties.branch;
          if (branch) {
            for (const s of sessions.values()) {
              s.branch = branch;
              writeSession(s);
            }
          }
          break;
        }
      }
    },

    // Called before each tool executes.
    "tool.execute.before": async ({ tool, sessionID }, output) => {
      const s = sessions.get(sessionID);
      if (!s) return;
      s.status = "working";
      s.last_activity = nowISO();
      s.last_tool = tool;
      s.last_tool_detail = output?.args
        ? JSON.stringify(output.args).slice(0, 120)
        : null;
      writeSession(s);
    },

    // Called after each tool completes — keep last_activity fresh.
    "tool.execute.after": async ({ sessionID }) => {
      const s = sessions.get(sessionID);
      if (!s) return;
      s.last_activity = nowISO();
      writeSession(s);
    },

    // Called when opencode asks for permission (tool approval).
    "permission.ask": async (input) => {
      const s = sessions.get(input.sessionID);
      if (!s) return;
      s.status = "waiting_permission";
      s.last_activity = nowISO();
      s.notification_message = input.title || "Permission needed";
      writeSession(s);
    },
  };
};
