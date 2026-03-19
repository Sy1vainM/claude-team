#!/usr/bin/env bash
# Stop the multi-agent team: kill tmux session.
#
# Usage: team-stop [--clean] [session-name]
#   --clean: also delete saved session IDs (prevents resume)
#   If no name given, auto-detects if only one session.
set -euo pipefail

CLEAN=false
SESSION=""

while [ "${1:-}" != "" ]; do
    case "$1" in
        --clean)
            CLEAN=true
            shift
            ;;
        *)
            SESSION="$1"
            shift
            ;;
    esac
done

_stop_session() {
    local sess="$1"
    if ! tmux has-session -t "$sess" 2>/dev/null; then
        echo "No session named '$sess' found."
        return 1
    fi

    # Get project dir before killing session (for --clean)
    local project_dir
    project_dir=$(tmux display-message -t "${sess}.0" -p '#{pane_current_path}' 2>/dev/null || true)

    tmux kill-session -t "$sess"
    echo "Team session '$sess' stopped."

    if [ "$CLEAN" = true ] && [ -n "$project_dir" ] && [ -d "$project_dir/.team" ]; then
        rm -rf "$project_dir/.team/sessions"
        rm -f "$project_dir/.team/last_config.yaml"
        echo "  Cleared saved session IDs and config (next start will be fresh)."
    fi
}

if [ -n "$SESSION" ]; then
    _stop_session "$SESSION"
    exit 0
fi

# Auto-detect
SESSIONS=$(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^team-" || true)

if [ -z "$SESSIONS" ]; then
    echo "No team sessions running."
    exit 0
fi

COUNT=$(echo "$SESSIONS" | wc -l | tr -d ' ')
if [ "$COUNT" -eq 1 ]; then
    _stop_session "$SESSIONS"
else
    echo "Multiple team sessions running:"
    echo "$SESSIONS" | while read -r s; do echo "  $s"; done
    echo ""
    echo "Usage: team-stop [--clean] <session-name>"
fi
