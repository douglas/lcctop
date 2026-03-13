#!/bin/sh
# run-hook.sh — Locate and run lcctop-hook.
# Shipped with the lcctop Claude Code plugin.
# Buffers stdin, logs a SHIM entry to the per-session log, then dispatches.

EVENT="$1"
umask 077
LOGS_DIR="$HOME/.cctop/logs"
mkdir -p "$LOGS_DIR"

# Buffer stdin so we can log before dispatching
INPUT=$(cat)

# Extract session ID and project label for logging
CWD=$(printf '%s' "$INPUT" | sed -n 's/.*"cwd" *: *"\([^"]*\)".*/\1/p' | head -1)
SID=$(printf '%s' "$INPUT" | sed -n 's/.*"session_id" *: *"\([^"]*\)".*/\1/p' | head -1)
SID=$(printf '%s' "$SID" | tr -cd 'a-zA-Z0-9_-')
PROJECT=$(basename "$CWD")
LABEL="${PROJECT:-unknown}:$(printf '%s' "$SID" | cut -c1-8)"
LOG="$LOGS_DIR/${SID}.log"
TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

printf '%s SHIM %s %s dispatching\n' "$TS" "$EVENT" "$LABEL" >> "$LOG" 2>/dev/null

# Find lcctop-hook in order of preference
if [ -x "$HOME/.local/bin/lcctop-hook" ]; then
    printf '%s' "$INPUT" | "$HOME/.local/bin/lcctop-hook" "$EVENT"
elif command -v lcctop-hook >/dev/null 2>&1; then
    printf '%s' "$INPUT" | lcctop-hook "$EVENT"
else
    printf '%s ERROR run-hook.sh: lcctop-hook not found (%s event=%s)\n' "$TS" "$LABEL" "$EVENT" >> "$LOG" 2>/dev/null
fi
