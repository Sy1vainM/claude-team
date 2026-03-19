#!/usr/bin/env bash
# One-click installer for claude-team.
# Usage: /path/to/claude-team/scripts/install.sh
set -euo pipefail

TEAM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENV_DIR="$TEAM_DIR/.venv"
PYTHON_BIN="$VENV_DIR/bin/python3"

echo "=== Claude Team Installer ==="
echo ""

# --- 1. Superpowers plugin ---
echo "[1/5] Installing superpowers plugin..."
if claude plugins list 2>/dev/null | grep -q "superpowers"; then
    echo "  superpowers already installed, skipping."
else
    claude plugins install superpowers@claude-plugins-official
fi
echo "  Done."

# --- 2. Python environment (uv) ---
echo "[2/5] Setting up Python environment..."
if ! command -v uv &>/dev/null; then
    echo "  Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi

if [ -d "$VENV_DIR" ]; then
    echo "  venv already exists, skipping."
else
    uv venv --python 3.12 "$VENV_DIR"
fi
uv pip install --python "$PYTHON_BIN" -q mcp
echo "  Done."

# --- 3. PATH symlinks ---
BIN_DIR="$HOME/.local/bin"
echo "[3/5] Creating command symlinks in $BIN_DIR..."
mkdir -p "$BIN_DIR"
ln -sf "$TEAM_DIR/scripts/team-start.sh" "$BIN_DIR/team-start"
ln -sf "$TEAM_DIR/scripts/team-stop.sh" "$BIN_DIR/team-stop"
ln -sf "$TEAM_DIR/scripts/team-status.sh" "$BIN_DIR/team-status"
ln -sf "$TEAM_DIR/scripts/team-add.sh" "$BIN_DIR/team-add"
ln -sf "$TEAM_DIR/scripts/team-remove.sh" "$BIN_DIR/team-remove"

if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
    SHELL_RC="$HOME/.zshrc"
    [ -f "$HOME/.bashrc" ] && [ ! -f "$HOME/.zshrc" ] && SHELL_RC="$HOME/.bashrc"
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
    echo "  Added ~/.local/bin to PATH in $SHELL_RC (restart shell or run: source $SHELL_RC)"
else
    echo "  ~/.local/bin already in PATH."
fi
echo "  Done."

# --- 4. Register MCP server ---
echo "[4/5] Registering MCP server in ~/.claude.json..."
CLAUDE_JSON="$HOME/.claude.json"

if [ ! -f "$CLAUDE_JSON" ]; then
    echo '{}' > "$CLAUDE_JSON"
fi

python3 -c "
import json, sys

with open('$CLAUDE_JSON', 'r') as f:
    config = json.load(f)

if 'mcpServers' not in config:
    config['mcpServers'] = {}

if 'team-mail' in config['mcpServers']:
    print('  team-mail already registered, skipping.')
    sys.exit(0)

config['mcpServers']['team-mail'] = {
    'type': 'stdio',
    'command': '$PYTHON_BIN',
    'args': ['$TEAM_DIR/mcp-server/server.py'],
    'env': {
        'TEAM_DB_PATH': '$TEAM_DIR/mcp-server/team.db'
    }
}

with open('$CLAUDE_JSON', 'w') as f:
    json.dump(config, f, indent=2)
print('  Registered team-mail MCP server.')
"
echo "  Done."

# --- 5. Register hook + skill ---
echo "[5/5] Registering hook and /team skill..."
SETTINGS_JSON="$HOME/.claude/settings.json"

if [ ! -f "$SETTINGS_JSON" ]; then
    echo '{}' > "$SETTINGS_JSON"
fi

python3 -c "
import json, sys

with open('$SETTINGS_JSON', 'r') as f:
    config = json.load(f)

hook_cmd = '$PYTHON_BIN $TEAM_DIR/hooks/inject-messages.py'

if 'hooks' not in config:
    config['hooks'] = {}

if 'UserPromptSubmit' not in config['hooks']:
    config['hooks']['UserPromptSubmit'] = []

# Check if already registered
for entry in config['hooks']['UserPromptSubmit']:
    for h in entry.get('hooks', []):
        if 'inject-messages' in h.get('command', ''):
            print('  Hook already registered, skipping.')
            sys.exit(0)

config['hooks']['UserPromptSubmit'].append({
    'matcher': '',
    'hooks': [{
        'type': 'command',
        'command': hook_cmd
    }]
})

with open('$SETTINGS_JSON', 'w') as f:
    json.dump(config, f, indent=2)
print('  Registered UserPromptSubmit hook.')
"

mkdir -p "$HOME/.claude/commands"
ln -sf "$TEAM_DIR/skills/team.md" "$HOME/.claude/commands/team.md"
echo "  Done."

echo ""
echo "=== Installation complete ==="
echo ""
echo "  Commands:  team-start, team-stop, team-status"
echo "  Skill:     /team"
echo ""
echo "  Quick start:"
echo "    cd /path/to/project"
echo "    team-start ."
echo "    tmux attach -t team-<dirname>"
