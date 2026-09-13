#!/bin/zsh
# Drives the Code card through a scripted session for screen recordings:
# thinking (dots) → creating (pencil) → completed (check), without a real agent.
#
# Usage: scripts/demo-code-card.sh [thinking-seconds] [creating-seconds] [start-delay]
#   defaults: 3 3 5   (the delay gives you time to hit Record)
#
# It talks to the running Notch app through the same notch-hook bridge Claude Code uses.
set -euo pipefail
THINK=${1:-3}
CREATE=${2:-3}
DELAY=${3:-5}

HOOK="$(dirname "$0")/../build/Build/Products/Debug/Notch.app/Contents/MacOS/notch-hook"
[[ -x "$HOOK" ]] || HOOK="/Applications/Notch.app/Contents/MacOS/notch-hook"
[[ -x "$HOOK" ]] || { echo "notch-hook not found; build the app or install it to /Applications" >&2; exit 1; }

SESSION="demo-$(date +%s)"
send() { printf '%s' "$1" | "$HOOK" claude; }

echo "recording starts in ${DELAY}s…"; sleep "$DELAY"
send "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$SESSION\",\"cwd\":\"$HOME\",\"prompt\":\"demo\"}"
echo "thinking (${THINK}s)"; sleep "$THINK"
send "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"$SESSION\",\"cwd\":\"$HOME\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"Demo.swift\"}}"
echo "creating (${CREATE}s)"; sleep "$CREATE"
send "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"$SESSION\",\"cwd\":\"$HOME\",\"tool_name\":\"Edit\"}"
send "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SESSION\",\"cwd\":\"$HOME\",\"stop_hook_active\":false,\"background_tasks\":[]}"
echo "completed"
