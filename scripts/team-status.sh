#!/usr/bin/env bash
# Show status of multi-agent team(s).
#
# Usage: team-status [session-name]
#   If no name given, shows all team sessions.
set -euo pipefail

# Resolve symlinks (macOS compatible) to find the real repo location
_script="$0"
while [ -L "$_script" ]; do
    _dir="$(cd "$(dirname "$_script")" && pwd)"
    _script="$(readlink "$_script")"
    [[ "$_script" != /* ]] && _script="$_dir/$_script"
done
TEAM_DIR="$(cd "$(dirname "$_script")/.." && pwd)"
DB_PATH="$TEAM_DIR/mcp-server/team.db"

show_session() {
    local session="$1"
    echo "=== $session ==="
    echo ""
    echo "Agents:"
    tmux list-panes -t "$session" -F "  [#{pane_index}] #{@agent_name} — #{pane_current_command}" 2>/dev/null || \
        echo "  (unable to list panes)"
    echo ""
}

# Find sessions
if [ -n "${1:-}" ]; then
    SESSIONS="$1"
else
    SESSIONS=$(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^team-" || true)
fi

if [ -z "$SESSIONS" ]; then
    echo "No team sessions running."
    echo "  Run 'team-start <project-dir>' to start."
    exit 0
fi

echo "$SESSIONS" | while read -r s; do
    show_session "$s"
done

# Message stats
if [ -f "$DB_PATH" ]; then
    echo "=== Messages ==="

    # Get agents dynamically: try roster.json from any active session's project dir
    AGENTS=""
    if [ -n "${SESSIONS:-}" ]; then
        # Get the first session's pane cwd to find roster.json
        first_session=$(echo "$SESSIONS" | head -1)
        pane_cwd=$(tmux display-message -t "${first_session}.0" -p '#{pane_current_path}' 2>/dev/null || true)
        if [ -n "$pane_cwd" ] && [ -f "$pane_cwd/.team/roster.json" ]; then
            AGENTS=$(python3 -c "import json; print(' '.join(json.load(open('$pane_cwd/.team/roster.json')).keys()))" 2>/dev/null || true)
        fi
    fi
    # Fallback to querying all distinct agents from DB
    if [ -z "$AGENTS" ]; then
        AGENTS=$(sqlite3 "$DB_PATH" "SELECT DISTINCT to_agent FROM messages;" 2>/dev/null || true)
    fi

    for agent in $AGENTS; do
        count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM messages WHERE to_agent='$agent' AND read=0;" 2>/dev/null || echo "?")
        echo "  $agent: $count unread"
    done
    total=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM messages;" 2>/dev/null || echo "?")
    echo "  Total: $total messages"
fi
