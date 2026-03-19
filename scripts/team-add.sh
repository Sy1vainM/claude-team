#!/usr/bin/env bash
# Add an agent to a running team session.
#
# Usage: team-add <role> [--name NAME] [--model MODEL] [--lang LANG] [--yolo] [--session SESSION]
#   role: agent role (e.g. tester, researcher, developer)
#   --name: display name (defaults to role)
#   --model: Claude model to use
#   --lang: language for agent communication (default: English)
#   --yolo: skip permission prompts
#   --session: target session (auto-detects if only one team session)

set -euo pipefail

# Resolve symlinks (macOS compatible)
_script="$0"
while [ -L "$_script" ]; do
    _dir="$(cd "$(dirname "$_script")" && pwd)"
    _script="$(readlink "$_script")"
    [[ "$_script" != /* ]] && _script="$_dir/$_script"
done
TEAM_DIR="$(cd "$(dirname "$_script")/.." && pwd)"

# --- Parse arguments ---
ROLE=""
NAME=""
MODEL=""
YOLO=""
SESSION=""
TEAM_LANG=""

while [ "${1:-}" != "" ]; do
    case "$1" in
        --name)
            NAME="$2"
            shift 2
            ;;
        --model)
            MODEL="$2"
            shift 2
            ;;
        --lang)
            TEAM_LANG="$2"
            shift 2
            ;;
        --yolo)
            YOLO="--yolo"
            shift
            ;;
        --session)
            SESSION="$2"
            shift 2
            ;;
        -*)
            echo "Unknown flag: $1" >&2
            exit 1
            ;;
        *)
            if [ -z "$ROLE" ]; then
                ROLE="$1"
            else
                echo "Unexpected argument: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [ -z "$ROLE" ]; then
    echo "Usage: team-add <role|name> [--name NAME] [--model MODEL] [--yolo] [--session SESSION]" >&2
    echo "" >&2
    echo "Available roles:" >&2
    ls "$TEAM_DIR/agents/" | sed 's/.md$//' | sed 's/^/  /' >&2
    exit 1
fi

# --- Check if ROLE is actually a previously removed agent name ---
# (e.g. "team-add Dan" to re-add a removed agent)
_resolve_removed() {
    # This is called after PROJECT_DIR is known; defined here as a function
    local removed_file="$1/.team/removed.json"
    if [ -f "$removed_file" ]; then
        python3 -c "
import json
with open('$removed_file') as f:
    removed = json.load(f)
name = '$ROLE'
if name in removed:
    print(removed[name])
" 2>/dev/null
    fi
}

# --- Find agent definition ---
if [ -f "$TEAM_DIR/agents/${ROLE}.md" ]; then
    AGENT_DEF="$ROLE"
elif [ -n "$NAME" ] && [ -f "$TEAM_DIR/agents/${NAME}.md" ]; then
    AGENT_DEF="$NAME"
else
    # Might be a removed agent name — defer resolution until after PROJECT_DIR
    AGENT_DEF=""
fi

# --- Find target session ---
if [ -z "$SESSION" ]; then
    SESSIONS=$(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^team-" || true)
    COUNT=$(echo "$SESSIONS" | grep -c . || true)
    if [ "$COUNT" -eq 0 ]; then
        echo "Error: No running team sessions found" >&2
        exit 1
    elif [ "$COUNT" -eq 1 ]; then
        SESSION="$SESSIONS"
    else
        echo "Error: Multiple team sessions running. Specify one with --session:" >&2
        echo "$SESSIONS" | sed 's/^/  /' >&2
        exit 1
    fi
fi

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Error: Session '$SESSION' not found" >&2
    exit 1
fi

# --- Get project dir from existing pane ---
PROJECT_DIR=$(tmux display-message -t "${SESSION}.0" -p '#{pane_current_path}')
if [ -z "$PROJECT_DIR" ] || [ ! -d "$PROJECT_DIR/.team" ]; then
    echo "Error: Cannot determine project directory from session" >&2
    exit 1
fi

# --- Resolve removed agent name → role ---
if [ -z "$AGENT_DEF" ]; then
    RESOLVED_ROLE=$(_resolve_removed "$PROJECT_DIR")
    if [ -n "$RESOLVED_ROLE" ] && [ -f "$TEAM_DIR/agents/${RESOLVED_ROLE}.md" ]; then
        # ROLE was actually a name (e.g. "Dan"), set NAME and resolve ROLE
        NAME="$ROLE"
        ROLE="$RESOLVED_ROLE"
        AGENT_DEF="$ROLE"
        echo "Restoring removed agent '$NAME' (role: $ROLE)"
    else
        echo "Error: No agent definition for '$ROLE'" >&2
        echo "Available roles:" >&2
        ls "$TEAM_DIR/agents/" | sed 's/.md$//' | sed 's/^/  /' >&2
        exit 1
    fi
fi

# --- Auto-assign name and check conflicts ---
ROSTER_FILE="$PROJECT_DIR/.team/roster.json"

# Auto-assign human name if not specified
if [ -z "$NAME" ]; then
    NAME=$(python3 -c "
import json, random, os

DEFAULT_NAMES = {
    'leader': 'Ada', 'planner': 'Bob', 'researcher': 'Cat',
    'developer': 'Dan', 'developer-fast': 'Eve', 'reviewer': 'Fox',
    'tester': 'Gil', 'writer': 'Hal',
}

NAME_POOL = [
    'Ada', 'Bob', 'Cat', 'Dan', 'Eve', 'Fox', 'Gil', 'Hal',
    'Ivy', 'Jay', 'Kay', 'Leo', 'Max', 'Nia', 'Oak', 'Pip',
    'Rex', 'Sky', 'Tao', 'Uma',
]

role = '$ROLE'

# Names in active roster
try:
    with open('$ROSTER_FILE') as f:
        used = set(json.load(f).keys())
except (FileNotFoundError, json.JSONDecodeError):
    used = set()

# Names with saved session IDs (removed agents that can be resumed)
sessions_dir = '$PROJECT_DIR/.team/sessions'
if os.path.isdir(sessions_dir):
    for f in os.listdir(sessions_dir):
        if f.endswith('.id'):
            used.add(f[:-3])

default = DEFAULT_NAMES.get(role, '')
if default and default not in used:
    print(default)
else:
    available = [n for n in NAME_POOL if n not in used]
    if available:
        print(random.choice(available))
    else:
        print(role)
")
fi
if [ -f "$ROSTER_FILE" ]; then
    if python3 -c "import json; r=json.load(open('$ROSTER_FILE')); exit(0 if '$NAME' in r else 1)" 2>/dev/null; then
        echo "Error: Agent '$NAME' already exists in this session" >&2
        exit 1
    fi
fi

# --- Add new pane ---
# Split horizontally (add column) — height is precious, sacrifice width
LAST_PANE=$(tmux list-panes -t "$SESSION" -F "#{pane_index}" | tail -1)
tmux split-window -h -t "${SESSION}.${LAST_PANE}"
NEW_PANE=$(tmux list-panes -t "$SESSION" -F "#{pane_index}" | tail -1)
# Apply optimal layout: 1-4 → 1 row, 5-8 → 2 rows, 9+ → 3 rows
"$TEAM_DIR/scripts/apply-layout.sh" "$SESSION"

# --- Update roster.json ---
python3 -c "
import json
roster_path = '$ROSTER_FILE'
try:
    with open(roster_path) as f:
        roster = json.load(f)
except FileNotFoundError:
    roster = {}
roster['$NAME'] = $NEW_PANE
with open(roster_path, 'w') as f:
    json.dump(roster, f)
"

# --- Update team_roster.md ---
python3 -c "
import json
with open('$ROSTER_FILE') as f:
    roster = json.load(f)
lines = ['## Current Team Roster', '']
lines.append('| Pane | Name | Role |')
lines.append('|------|------|------|')
for name, pane in sorted(roster.items(), key=lambda x: x[1]):
    lines.append(f'| {pane} | {name} | {name} |')
lines.append('')
lines.append('Use these exact names when sending messages with mcp__team-mail__send_message.')
with open('$PROJECT_DIR/.team/team_roster.md', 'w') as f:
    f.write('\n'.join(lines))
"

# --- Update last_config.yaml ---
LAST_CONFIG="$PROJECT_DIR/.team/last_config.yaml"
if [ -f "$LAST_CONFIG" ]; then
    # Append the new agent to the saved config
    echo "  - role: $ROLE" >> "$LAST_CONFIG"
    [ "$NAME" != "$ROLE" ] && echo "    name: $NAME" >> "$LAST_CONFIG"
    [ -n "$MODEL" ] && echo "    model: $MODEL" >> "$LAST_CONFIG"
fi

# --- Inherit yolo from session ---
if [ -z "$YOLO" ] && [ -f "$PROJECT_DIR/.team/yolo" ]; then
    YOLO="--yolo"
fi

# --- Launch agent ---
launch_cmd=""
[ -n "$TEAM_LANG" ] && launch_cmd+="TEAM_LANG='${TEAM_LANG}' "
launch_cmd+="$TEAM_DIR/scripts/agent-launch.sh '${AGENT_DEF}' '${PROJECT_DIR}' '${SESSION}' '${NAME}'"
[ -n "$MODEL" ] && launch_cmd+=" --model '${MODEL}'"
[ -n "$YOLO" ] && launch_cmd+=" ${YOLO}"

tmux send-keys -t "${SESSION}.${NEW_PANE}" "$launch_cmd" Enter
if [ "$NAME" = "$ROLE" ]; then
    pane_label="$NAME"
else
    pane_label="$NAME ($ROLE)"
fi
tmux set-option -p -t "${SESSION}.${NEW_PANE}" @agent_name "$pane_label"

# --- Clean up removed.json if this was a re-add ---
REMOVED_FILE="$PROJECT_DIR/.team/removed.json"
if [ -f "$REMOVED_FILE" ]; then
    python3 -c "
import json
with open('$REMOVED_FILE') as f:
    removed = json.load(f)
removed.pop('$NAME', None)
with open('$REMOVED_FILE', 'w') as f:
    json.dump(removed, f)
" 2>/dev/null || true
fi

echo "Added '$NAME' (role: $ROLE) to session '$SESSION' at pane $NEW_PANE"
echo ""
echo "  tmux attach -t $SESSION    — enter the team"
echo "  Ctrl+B q $NEW_PANE              — jump to $NAME"
