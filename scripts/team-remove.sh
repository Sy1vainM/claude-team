#!/usr/bin/env bash
# Remove an agent from a running team session.
#
# Usage: team-remove <agent-name> [--session SESSION]
#   The agent's tmux pane is killed, roster and config are updated.
#   Session ID is preserved — the agent can be re-added and resumed later.

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
AGENT_NAME=""
SESSION=""

while [ "${1:-}" != "" ]; do
    case "$1" in
        --session)
            SESSION="$2"
            shift 2
            ;;
        -*)
            echo "Unknown flag: $1" >&2
            exit 1
            ;;
        *)
            if [ -z "$AGENT_NAME" ]; then
                AGENT_NAME="$1"
            else
                echo "Unexpected argument: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [ -z "$AGENT_NAME" ]; then
    echo "Usage: team-remove <agent-name> [--session SESSION]" >&2
    exit 1
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

# --- Get project dir ---
PROJECT_DIR=$(tmux display-message -t "${SESSION}.0" -p '#{pane_current_path}' 2>/dev/null || true)
if [ -z "$PROJECT_DIR" ] || [ ! -d "$PROJECT_DIR/.team" ]; then
    echo "Error: Cannot determine project directory from session" >&2
    exit 1
fi

# --- Find pane index from roster ---
ROSTER_FILE="$PROJECT_DIR/.team/roster.json"
if [ ! -f "$ROSTER_FILE" ]; then
    echo "Error: No roster.json found" >&2
    exit 1
fi

PANE_INDEX=$(python3 -c "
import json, sys
with open('$ROSTER_FILE') as f:
    roster = json.load(f)
if '$AGENT_NAME' not in roster:
    print('NOT_FOUND')
else:
    print(roster['$AGENT_NAME'])
")

if [ "$PANE_INDEX" = "NOT_FOUND" ]; then
    echo "Error: Agent '$AGENT_NAME' not found in roster" >&2
    echo "Active agents:" >&2
    python3 -c "import json; [print(f'  {k}') for k in json.load(open('$ROSTER_FILE'))]"
    exit 1
fi

# Don't allow removing the leader
if [ "$AGENT_NAME" = "leader" ]; then
    echo "Error: Cannot remove leader" >&2
    exit 1
fi

# --- Save removed agent info (name → role) for re-adding later ---
python3 -c "
import json, re, subprocess

removed_path = '$PROJECT_DIR/.team/removed.json'
try:
    with open(removed_path) as f:
        removed = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    removed = {}

# Get role from pane label
result = subprocess.run(
    ['tmux', 'display-message', '-t', '${SESSION}.${PANE_INDEX}', '-p', '#{@agent_name}'],
    capture_output=True, text=True
)
label = result.stdout.strip()
import re
m = re.match(r'^(.+?)\s+\((.+)\)$', label)
role = m.group(2) if m else label

removed['$AGENT_NAME'] = role
with open(removed_path, 'w') as f:
    json.dump(removed, f)
"

# --- Kill the pane ---
tmux kill-pane -t "${SESSION}.${PANE_INDEX}" 2>/dev/null || true
"$TEAM_DIR/scripts/apply-layout.sh" "$SESSION" 2>/dev/null || true

# --- Update roster.json (rebuild from tmux panes) ---
python3 -c "
import json, subprocess, re

# Get current pane-to-agent mapping from tmux
result = subprocess.run(
    ['tmux', 'list-panes', '-t', '$SESSION', '-F', '#{pane_index} #{@agent_name}'],
    capture_output=True, text=True
)
roster = {}
roles = {}
for line in result.stdout.strip().split('\n'):
    if line.strip():
        parts = line.strip().split(' ', 1)
        if len(parts) == 2 and parts[1]:
            label = parts[1]
            # Parse 'name (role)' or just 'name'
            m = re.match(r'^(.+?)\s+\((.+)\)$', label)
            if m:
                name, role = m.group(1), m.group(2)
            else:
                name, role = label, label
            roster[name] = int(parts[0])
            roles[name] = role

with open('$ROSTER_FILE', 'w') as f:
    json.dump(roster, f)

# Update team_roster.md
lines = ['## Current Team Roster', '']
lines.append('| Pane | Name | Role |')
lines.append('|------|------|------|')
for name, pane in sorted(roster.items(), key=lambda x: x[1]):
    lines.append(f'| {pane} | {name} | {roles.get(name, name)} |')
lines.append('')
lines.append('Use these exact names when sending messages with mcp__team-mail__send_message.')
with open('$PROJECT_DIR/.team/team_roster.md', 'w') as f:
    f.write('\n'.join(lines))
"

# --- Update last_config.yaml ---
LAST_CONFIG="$PROJECT_DIR/.team/last_config.yaml"
if [ -f "$LAST_CONFIG" ]; then
    python3 -c "
import json, subprocess, re

# Read current roster to know who's still active
with open('$ROSTER_FILE') as f:
    roster = json.load(f)

# Get roles from tmux pane labels
result = subprocess.run(
    ['tmux', 'list-panes', '-t', '$SESSION', '-F', '#{pane_index} #{@agent_name}'],
    capture_output=True, text=True
)
roles = {}
for line in result.stdout.strip().split('\n'):
    if line.strip():
        parts = line.strip().split(' ', 1)
        if len(parts) == 2 and parts[1]:
            label = parts[1]
            m = re.match(r'^(.+?)\s+\((.+)\)$', label)
            if m:
                roles[m.group(1)] = m.group(2)
            else:
                roles[label] = label

# Rebuild config from roster + roles
config_lines = ['team:']
for name in sorted(roster.keys(), key=lambda k: roster[k]):
    role = roles.get(name, name)
    config_lines.append(f'  - role: {role}')
    if name != role:
        config_lines.append(f'    name: {name}')

with open('$LAST_CONFIG', 'w') as f:
    f.write('\n'.join(config_lines) + '\n')
"
fi

echo "Removed '$AGENT_NAME' from session '$SESSION'"
echo "  Session ID preserved — use 'team-add $AGENT_NAME' to bring them back."
