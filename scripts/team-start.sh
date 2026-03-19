#!/usr/bin/env bash
# Start a multi-agent team: N Claude Code sessions in tmux panes.
#
# Usage: team-start [--yolo] [--preset NAME] [--config FILE] [--lang LANG] [project-dir] [session-name]
#   --yolo: skip permission prompts for all agents
#   --preset NAME: use a preset team (default, research, minimal)
#   --config FILE: use a custom team.yaml
#   --lang LANG: language for agent communication (default: English)
#   project-dir defaults to current directory
#   session-name defaults to "team-<dirname>"

set -euo pipefail

# Resolve symlinks (macOS compatible) to find the real repo location
_script="$0"
while [ -L "$_script" ]; do
    _dir="$(cd "$(dirname "$_script")" && pwd)"
    _script="$(readlink "$_script")"
    [[ "$_script" != /* ]] && _script="$_dir/$_script"
done
TEAM_DIR="$(cd "$(dirname "$_script")/.." && pwd)"
YOLO=""
PRESET=""
CONFIG_FILE=""
TEAM_LANG=""

# --- Parse flags ---
while [ "${1:-}" != "" ]; do
    case "$1" in
        --yolo)
            YOLO="--yolo"
            shift
            ;;
        --preset)
            PRESET="$2"
            shift 2
            ;;
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --lang)
            TEAM_LANG="$2"
            shift 2
            ;;
        *)
            break
            ;;
    esac
done

PROJECT_DIR="${1:-.}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
DIR_NAME="$(basename "$PROJECT_DIR")"
SESSION="${2:-team-${DIR_NAME}}"
DB_PATH="$TEAM_DIR/mcp-server/team.db"

# --- Resolve team config ---

resolve_team_config() {
    # Priority: --config > --preset > .team/team.yaml > saved config (resume) > default
    if [ -n "$CONFIG_FILE" ]; then
        echo "$CONFIG_FILE"
    elif [ -n "$PRESET" ]; then
        local preset_file="$TEAM_DIR/presets/${PRESET}.yaml"
        if [ ! -f "$preset_file" ]; then
            echo "Error: Unknown preset '$PRESET'. Available: $(ls "$TEAM_DIR/presets/" | sed 's/.yaml//g' | tr '\n' ', ')" >&2
            exit 1
        fi
        echo "$preset_file"
    elif [ -f "$PROJECT_DIR/.team/team.yaml" ]; then
        echo "$PROJECT_DIR/.team/team.yaml"
    elif [ -f "$PROJECT_DIR/.team/last_config.yaml" ]; then
        # Resume: use the config from the previous session
        echo "$PROJECT_DIR/.team/last_config.yaml"
    else
        echo "$TEAM_DIR/presets/default.yaml"
    fi
}

TEAM_CONFIG="$(resolve_team_config)"

# --- Parse YAML (lightweight, no external deps) ---

parse_team_yaml() {
    local config="$1"
    # Extract role, optional name, and optional model fields from team.yaml
    # Output format: role:name:model (name defaults to role, model defaults to empty)
    python3 -c "
import sys

roles = []
current_role = None
current_name = None
current_model = None

with open('$config') as f:
    for line in f:
        line = line.strip()
        if line.startswith('- role:'):
            if current_role:
                roles.append(f'{current_role}:{current_name or current_role}:{current_model or \"\"}')
            current_role = line.split(':', 1)[1].strip()
            current_name = None
            current_model = None
        elif line.startswith('name:') and current_role:
            current_name = line.split(':', 1)[1].strip()
        elif line.startswith('model:') and current_role:
            current_model = line.split(':', 1)[1].strip()

if current_role:
    roles.append(f'{current_role}:{current_name or current_role}:{current_model or \"\"}')

for r in roles:
    print(r)
"
}

# Read agents from config (compatible with bash 3 on macOS)
AGENT_ENTRIES=()
while IFS= read -r line; do
    AGENT_ENTRIES+=("$line")
done < <(parse_team_yaml "$TEAM_CONFIG")
NUM_AGENTS=${#AGENT_ENTRIES[@]}

if [ "$NUM_AGENTS" -eq 0 ]; then
    echo "Error: No agents defined in $TEAM_CONFIG" >&2
    exit 1
fi

if [ "$NUM_AGENTS" -gt 9 ]; then
    echo "Error: Maximum 9 agents supported (got $NUM_AGENTS)" >&2
    exit 1
fi

# Split into parallel arrays (format: role:name:model)
ROLES=()
NAMES=()
MODELS=()
for entry in "${AGENT_ENTRIES[@]}"; do
    role="${entry%%:*}"
    rest="${entry#*:}"
    name="${rest%%:*}"
    model="${rest##*:}"
    ROLES+=("$role")
    NAMES+=("$name")
    MODELS+=("$model")
done

# --- Preflight checks ---

if ! command -v tmux &>/dev/null; then
    echo "Error: tmux is not installed" >&2
    exit 1
fi

if ! command -v claude &>/dev/null; then
    echo "Error: claude CLI is not installed" >&2
    exit 1
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Team session already running. Use 'team-stop' first or 'tmux attach -t $SESSION'."
    exit 0
fi

# --- Clean stale messages only on fresh start ---

if [ -f "$DB_PATH" ] && [ ! -f "$PROJECT_DIR/.team/PLAN.md" ]; then
    sqlite3 "$DB_PATH" "DELETE FROM messages WHERE session = '$SESSION';" 2>/dev/null || true
fi

# --- Create .team directory in project ---

mkdir -p "$PROJECT_DIR/.team"

# --- Block /team skill inside agent sessions ---

mkdir -p "$PROJECT_DIR/.claude/commands"
cat > "$PROJECT_DIR/.claude/commands/team.md" << 'BLOCK'
---
description: (blocked inside team sessions)
user-invocable: false
---
BLOCK

# --- Write agent roster for MCP server + leader context ---

python3 -c "
import json

names = '${NAMES[*]}'.split()
roles = '${ROLES[*]}'.split()

# roster.json: name -> pane index (for MCP server)
roster = {name: i for i, name in enumerate(names)}
with open('$PROJECT_DIR/.team/roster.json', 'w') as f:
    json.dump(roster, f)

# team_roster.md: human-readable roster (injected into leader prompt)
lines = ['## Current Team Roster', '']
lines.append('| Pane | Name | Role |')
lines.append('|------|------|------|')
for i, (name, role) in enumerate(zip(names, roles)):
    lines.append(f'| {i} | {name} | {role} |')
lines.append('')
lines.append('Use these exact names when sending messages with mcp__team-mail__send_message.')
with open('$PROJECT_DIR/.team/team_roster.md', 'w') as f:
    f.write('\n'.join(lines))

# last_config.yaml: save current team config for resume
models_raw = '${MODELS[*]}'
models = models_raw.split() if models_raw.strip() else []
config_lines = ['team:']
for i, (name, role) in enumerate(zip(names, roles)):
    config_lines.append(f'  - role: {role}')
    if name != role:
        config_lines.append(f'    name: {name}')
    if i < len(models) and models[i]:
        config_lines.append(f'    model: {models[i]}')
with open('$PROJECT_DIR/.team/last_config.yaml', 'w') as f:
    f.write('\n'.join(config_lines) + '\n')
"

# --- Create tmux session with dynamic layout ---

# Create session with first pane
tmux new-session -d -s "$SESSION" -x 200 -y 50

# Create remaining panes
for ((i = 1; i < NUM_AGENTS; i++)); do
    tmux split-window -h -t "${SESSION}.0"
done

# Apply optimal layout: 1-4 → 1 row, 5-8 → 2 rows, 9+ → 3 rows
"$TEAM_DIR/scripts/apply-layout.sh" "$SESSION"

# --- Detect resume vs fresh start BEFORE launching agents ---
# (agent-launch.sh creates session ID files, so must check before that)
IS_RESUME=false
if [ -d "$PROJECT_DIR/.team/sessions" ]; then
    for ((i = 0; i < NUM_AGENTS; i++)); do
        if [ -f "$PROJECT_DIR/.team/sessions/${NAMES[$i]}.id" ]; then
            IS_RESUME=true
            break
        fi
    done
fi

# --- Export language setting for agents ---
if [ -n "$TEAM_LANG" ]; then
    export TEAM_LANG
fi

# --- Start each agent ---

for ((i = 0; i < NUM_AGENTS; i++)); do
    role="${ROLES[$i]}"
    name="${NAMES[$i]}"
    model="${MODELS[$i]}"

    # Find the agent definition (try exact name first, then role)
    if [ -f "$TEAM_DIR/agents/${name}.md" ]; then
        agent_def="$name"
    elif [ -f "$TEAM_DIR/agents/${role}.md" ]; then
        agent_def="$role"
    else
        echo "Warning: No agent definition for '$role' / '$name', skipping" >&2
        continue
    fi

    # Build launch command with optional model
    launch_cmd=""
    [ -n "$TEAM_LANG" ] && launch_cmd+="TEAM_LANG='${TEAM_LANG}' "
    launch_cmd+="$TEAM_DIR/scripts/agent-launch.sh '${agent_def}' '${PROJECT_DIR}' '${SESSION}' '${name}'"
    [ -n "$model" ] && launch_cmd+=" --model '${model}'"
    [ -n "$YOLO" ] && launch_cmd+=" ${YOLO}"

    # Launch agent
    tmux send-keys -t "${SESSION}.${i}" "$launch_cmd" Enter

    # Label the pane (show role if name differs)
    if [ "$name" = "$role" ]; then
        pane_label="$name"
    else
        pane_label="$name ($role)"
    fi
    tmux set-option -p -t "${SESSION}.${i}" @agent_name "$pane_label"
done

# Enable pane titles
tmux set-option -t "$SESSION" pane-border-status top
tmux set-option -t "$SESSION" pane-border-format " #{@agent_name} "

# Wait for agents to start by polling pane content
echo "Waiting for agents to initialize..."
MAX_WAIT=30
WAITED=0
while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    READY=0
    for ((i = 0; i < NUM_AGENTS; i++)); do
        if tmux capture-pane -t "${SESSION}.${i}" -p 2>/dev/null | grep -qE '╭|>'; then
            READY=$((READY + 1))
        fi
    done
    if [ "$READY" -ge "$NUM_AGENTS" ]; then
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    echo "Warning: Timed out waiting for agents (${MAX_WAIT}s). Some may still be loading."
fi

# Only send initial prompt for fresh starts — resumed sessions have full context
if [ "$IS_RESUME" = false ]; then
    for ((i = 0; i < NUM_AGENTS; i++)); do
        tmux send-keys -t "${SESSION}.${i}" \
            "Briefly introduce yourself: your name, role, and what you can do. Then say you are ready." Enter
        sleep 1
    done
fi

# Select first pane (leader)
tmux select-pane -t "${SESSION}.0"

# --- Print summary ---

echo "Team started in tmux session '$SESSION'"
echo ""
echo "  Agents ($NUM_AGENTS): ${NAMES[*]}"
echo "  Config: $TEAM_CONFIG"
LAYOUT_ROWS=$( [ "$NUM_AGENTS" -le 4 ] && echo 1 || ( [ "$NUM_AGENTS" -le 8 ] && echo 2 || echo 3 ) )
echo "  Layout: ${NUM_AGENTS} panes, ${LAYOUT_ROWS} row(s)"
echo ""
echo "  tmux attach -t $SESSION    — enter the team"
echo "  Ctrl+B q 0-$((NUM_AGENTS-1))          — jump to pane"
echo "  Ctrl+B z                   — zoom/unzoom pane"
echo "  Ctrl+B d                   — detach (agents keep running)"
echo "  team-stop                  — stop all agents"
