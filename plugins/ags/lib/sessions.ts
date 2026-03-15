import GLib from "gi://GLib"
import Gio from "gi://Gio"
import { createExternal } from "ags"
import { Session, RawSession, SessionStatus, STATUS_PRIORITY, STATUS_COLORS, STATUS_LABELS } from "./types.js"

function readProcStat(pid: number): string[] | null {
    const path = `/proc/${pid}/stat`
    try {
        const file = Gio.File.new_for_path(path)
        const [ok, contents] = file.load_contents(null)
        if (!ok) return null
        const text = new TextDecoder().decode(contents)
        const parenClose = text.lastIndexOf(")")
        if (parenClose === -1) return null
        const before = text.slice(0, text.indexOf("("))
        const comm = text.slice(text.indexOf("(") + 1, parenClose)
        const after = text.slice(parenClose + 2)
        return [before.trim(), comm, ...after.trim().split(" ")]
    } catch { return null }
}

function isAlive(pid: number): boolean {
    const stat = readProcStat(pid)
    if (!stat) return false
    return stat[2] !== "Z" && stat[2] !== "X"
}

function relativeTime(isoStr: string): string {
    const now = GLib.get_real_time() / 1_000_000
    const then = new Date(isoStr).getTime() / 1000
    const diff = Math.max(0, now - then)
    if (diff < 60) return "just now"
    if (diff < 3600) return `${Math.floor(diff / 60)}m ago`
    if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`
    return `${Math.floor(diff / 86400)}d ago`
}

function buildContextLine(s: RawSession): string | null {
    switch (s.status) {
        case "idle": return null
        case "compacting": return "Compacting context..."
        case "waiting_permission": return s.notification_message ?? "Permission needed"
        case "waiting_input":
        case "needs_attention": {
            if (!s.last_prompt) return null
            const t = s.last_prompt.slice(0, 36)
            return `"${t}${s.last_prompt.length > 36 ? "…" : ""}"`
        }
        case "working": {
            if (!s.last_tool) return s.last_prompt ? `"${s.last_prompt.slice(0, 36)}"` : null
            const d = s.last_tool_detail ?? ""
            const tool = s.last_tool.toLowerCase()
            if (tool === "bash") return `Running: ${d.slice(0, 30)}`
            if (tool === "edit" || tool === "multiedit") return `Editing ${d}`
            if (tool === "read") return `Reading ${d}`
            if (tool === "write") return `Writing ${d}`
            if (tool === "glob" || tool === "grep") return `Searching ${d.slice(0, 30)}`
            if (tool === "task" || tool === "agent") return `Agent: ${d.slice(0, 30)}`
            return `${s.last_tool}: ${d.slice(0, 30)}`
        }
        default: return null
    }
}

function enrichSession(raw: RawSession): Session {
    const status = raw.status as SessionStatus
    const sourceLabel = (raw.source ?? "").toLowerCase() === "opencode" ? "OC" : "CC"
    return {
        ...raw,
        displayName: raw.session_name ?? raw.project_name,
        sourceLabel,
        statusLabel: STATUS_LABELS[status] ?? status,
        statusColor: STATUS_COLORS[status] ?? "#6c7086",
        contextLine: buildContextLine(raw),
        relativeTime: relativeTime(raw.last_activity),
        subagentCount: (raw.active_subagents ?? []).length,
    }
}

const SESSIONS_DIR = GLib.build_filenamev([GLib.get_home_dir(), ".cctop", "sessions"])

export function loadSessions(): Session[] {
    const dir = Gio.File.new_for_path(SESSIONS_DIR)
    let enumerator: Gio.FileEnumerator
    try {
        enumerator = dir.enumerate_children("standard::name,standard::type", Gio.FileQueryInfoFlags.NONE, null)
    } catch { return [] }
    const result: Session[] = []
    let info: Gio.FileInfo | null
    while ((info = enumerator.next_file(null)) !== null) {
        const name = info.get_name()
        if (!name.endsWith(".json")) continue
        const file = dir.get_child(name)
        let raw: RawSession
        try {
            const [ok, contents] = file.load_contents(null)
            if (!ok) continue
            raw = JSON.parse(new TextDecoder().decode(contents)) as RawSession
        } catch { continue }
        if (raw.pid && !isAlive(raw.pid)) continue
        result.push(enrichSession(raw))
    }
    enumerator.close(null)
    return result.sort((a, b) => {
        const pa = STATUS_PRIORITY[a.status as SessionStatus] ?? 99
        const pb = STATUS_PRIORITY[b.status as SessionStatus] ?? 99
        if (pa !== pb) return pa - pb
        return new Date(b.last_activity).getTime() - new Date(a.last_activity).getTime()
    })
}

// Reactive: polls every 2s while subscribed
export const sessions = createExternal<Session[]>(loadSessions(), (set) => {
    const id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 2000, () => {
        set(loadSessions())
        return GLib.SOURCE_CONTINUE
    })
    return () => GLib.source_remove(id)
})
