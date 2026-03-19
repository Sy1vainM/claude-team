#!/usr/bin/env bash
# Launch a single Claude Code agent with its identity.
# Called by team-start.sh inside each tmux pane.
#
# Usage: agent-launch.sh <agent-def> <project-dir> <session-name> <display-name> [--model MODEL] [--yolo]
#   agent-def: base name of the .md file in agents/ (e.g. "leader", "developer")
#   display-name: the agent's name in this session (may differ from agent-def)

set -euo pipefail

AGENT_DEF="$1"
PROJECT_DIR="$2"
SESSION_NAME="$3"
DISPLAY_NAME="$4"
shift 4

# Parse optional flags
MODEL=""
YOLO=""
while [ "${1:-}" != "" ]; do
    case "$1" in
        --model)
            MODEL="$2"
            shift 2
            ;;
        --yolo)
            YOLO="--yolo"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

TEAM_DIR="$(cd "$(dirname "$0")/.." && pwd)"

export TEAM_AGENT_NAME="$DISPLAY_NAME"
export TEAM_DB_PATH="$TEAM_DIR/mcp-server/team.db"
export TEAM_TMUX_SESSION="$SESSION_NAME"

cd "$PROJECT_DIR"

# Write session name to project dir so MCP server can read it (env inheritance unreliable)
echo "$SESSION_NAME" > "$PROJECT_DIR/.team/session_name"

AGENT_FILE="$TEAM_DIR/agents/${AGENT_DEF}.md"
if [ ! -f "$AGENT_FILE" ]; then
    echo "Error: Agent definition not found: $AGENT_FILE" >&2
    exit 1
fi

SYSTEM_PROMPT="$(cat "$AGENT_FILE")"

# Inject dynamic team roster into agent's prompt
ROSTER_FILE="$PROJECT_DIR/.team/team_roster.md"
if [ -f "$ROSTER_FILE" ]; then
    SYSTEM_PROMPT="$SYSTEM_PROMPT

$(cat "$ROSTER_FILE")"
fi

# Inject session info so agents (especially leader) can use --session flag
SYSTEM_PROMPT="$SYSTEM_PROMPT

## Session Info

- **Session name:** \`${SESSION_NAME}\`
- **Project directory:** \`${PROJECT_DIR}\`
- **Your name:** \`${DISPLAY_NAME}\`

When running team commands (team-add, team-remove, team-stop), always include \`--session ${SESSION_NAME}\` to avoid ambiguity with other running teams."

# Language setting: use TEAM_LANG env var, default to English
LANG_SETTING="${TEAM_LANG:-English}"
SYSTEM_PROMPT="$SYSTEM_PROMPT

## Language

You MUST communicate in ${LANG_SETTING}. All messages, reports, and output must be in ${LANG_SETTING} regardless of any other language instructions."

# --- Session resume support ---
SESSION_DIR="$PROJECT_DIR/.team/sessions"
mkdir -p "$SESSION_DIR"
SESSION_FILE="$SESSION_DIR/${DISPLAY_NAME}.id"

CLAUDE_ARGS=()

if [ -f "$SESSION_FILE" ]; then
    # Resume existing session
    SAVED_ID="$(cat "$SESSION_FILE")"
    CLAUDE_ARGS+=(--resume "$SAVED_ID")
    echo "Resuming $DISPLAY_NAME (session: $SAVED_ID)"
else
    # Fresh start: generate a UUID and save it
    NEW_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    echo "$NEW_ID" > "$SESSION_FILE"
    CLAUDE_ARGS+=(--session-id "$NEW_ID" --append-system-prompt "$SYSTEM_PROMPT" -n "$DISPLAY_NAME")
    echo "Starting $DISPLAY_NAME (session: $NEW_ID)"
fi

if [ -n "$MODEL" ]; then
    CLAUDE_ARGS+=(--model "$MODEL")
fi
if [ "$YOLO" = "--yolo" ]; then
    CLAUDE_ARGS+=(--dangerously-skip-permissions)
fi

exec claude "${CLAUDE_ARGS[@]}"
