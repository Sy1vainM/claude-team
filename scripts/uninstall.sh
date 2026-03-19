#!/usr/bin/env bash
# Uninstall claude-team: remove all config entries and symlinks.
# Usage: /path/to/claude-team/scripts/uninstall.sh
set -euo pipefail

TEAM_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Claude Team Uninstaller ==="
echo ""

# --- 1. Stop any running team sessions ---
echo "[1/5] Stopping running team sessions..."
SESSIONS=$(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^team-" || true)
if [ -n "$SESSIONS" ]; then
    echo "$SESSIONS" | while read -r s; do
        tmux kill-session -t "$s" 2>/dev/null || true
        echo "  Stopped $s"
    done
else
    echo "  No running sessions."
fi

# --- 2. Remove command symlinks ---
echo "[2/5] Removing command symlinks..."
for cmd in team-start team-stop team-status team-add team-remove; do
    for dir in "$HOME/.local/bin" "$HOME/bin"; do
        if [ -L "$dir/$cmd" ]; then
            rm "$dir/$cmd"
            echo "  Removed $dir/$cmd"
        fi
    done
done

# --- 3. Remove MCP server from ~/.claude.json ---
echo "[3/5] Removing MCP server from ~/.claude.json..."
CLAUDE_JSON="$HOME/.claude.json"
if [ -f "$CLAUDE_JSON" ]; then
    python3 -c "
import json, sys

with open('$CLAUDE_JSON', 'r') as f:
    config = json.load(f)

if 'mcpServers' in config and 'team-mail' in config['mcpServers']:
    del config['mcpServers']['team-mail']
    with open('$CLAUDE_JSON', 'w') as f:
        json.dump(config, f, indent=2)
    print('  Removed team-mail MCP server.')
else:
    print('  team-mail not found, skipping.')
"
else
    echo "  ~/.claude.json not found, skipping."
fi

# --- 4. Remove hook from ~/.claude/settings.json ---
echo "[4/5] Removing UserPromptSubmit hook from ~/.claude/settings.json..."
SETTINGS_JSON="$HOME/.claude/settings.json"
if [ -f "$SETTINGS_JSON" ]; then
    python3 -c "
import json, sys

with open('$SETTINGS_JSON', 'r') as f:
    config = json.load(f)

if 'hooks' in config and 'UserPromptSubmit' in config['hooks']:
    before = len(config['hooks']['UserPromptSubmit'])
    config['hooks']['UserPromptSubmit'] = [
        entry for entry in config['hooks']['UserPromptSubmit']
        if not any('inject-messages' in h.get('command', '') for h in entry.get('hooks', []))
    ]
    after = len(config['hooks']['UserPromptSubmit'])
    if before != after:
        with open('$SETTINGS_JSON', 'w') as f:
            json.dump(config, f, indent=2)
        print('  Removed inject-messages hook.')
    else:
        print('  Hook not found, skipping.')
else:
    print('  No hooks configured, skipping.')
"
else
    echo "  ~/.claude/settings.json not found, skipping."
fi

# --- 5. Remove /team skill symlink ---
echo "[5/5] Removing /team skill..."
if [ -L "$HOME/.claude/commands/team.md" ]; then
    rm "$HOME/.claude/commands/team.md"
    echo "  Removed ~/.claude/commands/team.md"
else
    echo "  Skill not found, skipping."
fi

# --- Remove database ---
if [ -f "$TEAM_DIR/mcp-server/team.db" ]; then
    rm "$TEAM_DIR/mcp-server/team.db"
    echo ""
    echo "Removed message database."
fi

echo ""
echo "=== Uninstall complete ==="
echo ""
echo "  The repo at $TEAM_DIR was NOT deleted."
echo "  To fully remove: rm -rf $TEAM_DIR"
echo ""
echo "  Optional cleanup:"
echo "    - Remove ~/bin from PATH in ~/.zshrc if no longer needed"
