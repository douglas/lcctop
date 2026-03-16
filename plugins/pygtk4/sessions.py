"""
Session loading and enrichment.
Port of plugins/ags/lib/sessions.ts + display adjustments from lib/lcctop/waybar_output.rb.
"""

import glob
import json
import os
import time

from colors import (
    STATUS_COLORS, STATUS_LABELS, STATUS_PRIORITY,
    SOURCE_BADGE_KEY, load_colors, resolve,
)

SESSIONS_DIR = os.path.expanduser("~/.cctop/sessions")
IDLE_TIMEOUT_SECONDS = 3600  # 60 minutes: waiting_input → idle for display


# ---------------------------------------------------------------------------
# /proc helpers
# ---------------------------------------------------------------------------

def read_proc_stat(pid: int) -> list[str] | None:
    """
    Parse /proc/{pid}/stat.
    Returns [pid_str, comm, state, ppid, pgrp, session, tty_nr, ...] or None.
    Index layout after comm: 0=state, 1=ppid, 4=tty_nr, 19=starttime.
    """
    try:
        with open(f"/proc/{pid}/stat") as f:
            text = f.read()
        paren_open  = text.index("(")
        paren_close = text.rindex(")")
        comm = text[paren_open + 1:paren_close]
        rest = text[paren_close + 2:].split()
        return [text[:paren_open].strip(), comm] + rest
    except Exception:
        return None


def is_alive(pid: int) -> bool:
    fields = read_proc_stat(pid)
    if not fields:
        return False
    # fields[2] = state (0=pid_str, 1=comm, 2=state)
    return fields[2] not in ("Z", "X")


def _process_start_time(pid: int) -> float | None:
    """Return starttime (jiffies) of a process, or None."""
    fields = read_proc_stat(pid)
    if not fields:
        return None
    try:
        # fields layout: [pid_str, comm, state, ppid, pgrp, session, tty_nr,
        #                  tpgid, flags, minflt, cminflt, majflt, cmajflt,
        #                  utime, stime, cutime, cstime, priority, nice,
        #                  num_threads, itrealvalue, starttime, ...]
        # After pid_str(0) and comm(1): state=2, ppid=3, ... starttime=2+19=21
        return float(fields[2 + 19])
    except Exception:
        return None


def _list_child_pids(pid: int) -> list[int]:
    """Find direct children of pid by scanning /proc/*/stat for ppid matches."""
    children = []
    for path in glob.glob("/proc/[0-9]*/stat"):
        try:
            with open(path) as f:
                content = f.read()
            right = content.rindex(")")
            fields = content[right + 2:].split()
            # fields[1] = ppid (relative to after closing paren)
            if int(fields[1]) == pid:
                children.append(int(os.path.basename(os.path.dirname(path))))
        except Exception:
            pass
    return children


# ---------------------------------------------------------------------------
# Time formatting
# ---------------------------------------------------------------------------

def relative_time(iso_str: str) -> str:
    try:
        # Handle both with and without timezone offset
        clean = iso_str[:19].replace("T", " ")
        then  = time.mktime(time.strptime(clean, "%Y-%m-%d %H:%M:%S"))
    except Exception:
        return "unknown"
    diff = max(0.0, time.time() - then)
    if diff < 60:    return "just now"
    if diff < 3600:  return f"{int(diff // 60)}m ago"
    if diff < 86400: return f"{int(diff // 3600)}h ago"
    return f"{int(diff // 86400)}d ago"


# ---------------------------------------------------------------------------
# Context line builder
# ---------------------------------------------------------------------------

def build_context_line(s: dict) -> str | None:
    status = s.get("status", "")
    if status == "idle":
        return None
    if status == "compacting":
        return "Compacting context..."
    if status == "waiting_permission":
        return s.get("notification_message") or "Permission needed"
    if status in ("waiting_input", "needs_attention"):
        prompt = s.get("last_prompt")
        if not prompt:
            return None
        t = prompt[:36]
        suffix = "…" if len(prompt) > 36 else ""
        return f'"{t}{suffix}"'
    if status == "working":
        tool   = (s.get("last_tool") or "").lower()
        detail = s.get("last_tool_detail") or ""
        if not tool:
            prompt = s.get("last_prompt")
            return f'"{prompt[:36]}"' if prompt else None
        if tool == "bash":                  return f"Running: {detail[:30]}"
        if tool in ("edit", "multiedit"):   return f"Editing {detail}"
        if tool == "read":                  return f"Reading {detail}"
        if tool == "write":                 return f"Writing {detail}"
        if tool in ("glob", "grep"):        return f"Searching {detail[:30]}"
        if tool in ("task", "agent"):       return f"Agent: {detail[:30]}"
        return f"{s.get('last_tool')}: {detail[:30]}"
    return None


# ---------------------------------------------------------------------------
# Session enrichment
# ---------------------------------------------------------------------------

def enrich_session(raw: dict, colors: dict) -> dict:
    status       = raw.get("status", "idle")
    source       = (raw.get("source") or "").lower()
    source_label = "OC" if source == "opencode" else "CC"

    color_key    = STATUS_COLORS.get(status, "gray")
    status_color = resolve(colors, color_key)

    src_key      = SOURCE_BADGE_KEY.get(source_label, "amber")
    source_color = resolve(colors, src_key)

    agents = raw.get("active_subagents") or []

    return {
        **raw,
        "display_name":   raw.get("session_name") or raw.get("project_name", ""),
        "source_label":   source_label,
        "status_label":   STATUS_LABELS.get(status, status.capitalize()),
        "status_color":   status_color,
        "source_color":   source_color,
        "context_line":   build_context_line(raw),
        "relative_time":  relative_time(raw.get("last_activity", "")),
        "subagent_count": len(agents),
    }


# ---------------------------------------------------------------------------
# Display adjustments (view-only, session files not modified)
# ---------------------------------------------------------------------------

def _last_activity_ts(session: dict) -> float:
    try:
        iso   = session.get("last_activity", "")
        clean = iso[:19].replace("T", " ")
        return time.mktime(time.strptime(clean, "%Y-%m-%d %H:%M:%S"))
    except Exception:
        return 0.0


def adjust_idle_timeout(session: dict) -> dict:
    """waiting_input that's been idle > 60 min → treat as idle for display."""
    if session.get("status") != "waiting_input":
        return session
    ts = _last_activity_ts(session)
    if ts and (time.time() - ts) > IDLE_TIMEOUT_SECONDS:
        return {**session, "status": "idle"}
    return session


def adjust_permission_status(session: dict) -> dict:
    """waiting_permission + child started after last_activity → show as working."""
    if session.get("status") != "waiting_permission":
        return session
    pid = session.get("pid")
    if not pid:
        return session
    cutoff = _last_activity_ts(session) - 1.0  # 1s tolerance for jitter
    for child_pid in _list_child_pids(pid):
        start = _process_start_time(child_pid)
        if start is not None and start > cutoff:
            return {**session, "status": "working"}
    return session


# ---------------------------------------------------------------------------
# Main loader
# ---------------------------------------------------------------------------

def _sort_key(s: dict) -> tuple:
    p = STATUS_PRIORITY.get(s.get("status", "idle"), 99)
    t = -_last_activity_ts(s)
    return (p, t)


def load_sessions() -> list[dict]:
    if not os.path.isdir(SESSIONS_DIR):
        return []

    colors   = load_colors()
    sessions = []

    for path in glob.glob(os.path.join(SESSIONS_DIR, "*.json")):
        try:
            with open(path) as f:
                raw = json.load(f)
        except Exception:
            continue

        pid = raw.get("pid")
        if pid and not is_alive(pid):
            continue

        raw = adjust_idle_timeout(raw)
        raw = adjust_permission_status(raw)
        sessions.append(enrich_session(raw, colors))

    sessions.sort(key=_sort_key)
    return sessions
