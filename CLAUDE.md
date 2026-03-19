# Claude Team

Multi-agent development team for Claude Code. 2–9 specialized agents running in tmux panes, communicating via MCP-based SQLite message bus.

## Quick Start

```bash
# Install (one-time)
./scripts/install.sh

# Start team for a project
cd /path/to/project
team-start .

# Enter the team
tmux attach -t team-<dirname>
```

## Project Structure

```
agents/          Agent identity definitions (markdown system prompts)
mcp-server/      MCP message bus (server.py + SQLite store.py)
scripts/         Shell scripts (install, start, stop, status, add, remove, layout)
skills/          Claude Code skills (/team command)
hooks/           UserPromptSubmit hook for fallback message injection
presets/         Team composition presets (default, minimal, research, full)
```

## Key Conventions

- **Python**: 3.12, managed by uv, only dependency is `mcp`
- **Shell scripts**: bash, `set -euo pipefail`, macOS bash 3.2 compatible (no mapfile)
- **Agent definitions**: English, markdown, define role/constraints/workflow/skills
- **MCP server**: FastMCP with stdio transport, 5 tools (send_message, broadcast, check_messages, list_threads, reply)
- **Message delivery**: Primary via `tmux load-buffer + paste-buffer + send-keys Enter`, fallback via UserPromptSubmit hook
- **SQLite**: WAL mode, busy timeout 5000ms, single shared DB at `mcp-server/team.db`
- **Symlink resolution**: All scripts resolve symlinks to find TEAM_DIR (macOS compatible, no `readlink -f`)

## Architecture

```
User ←→ tmux panes ←→ Claude Code sessions
                          ↕
                     MCP server (stdio)
                          ↕
                     SQLite (team.db)
                          ↕
                     tmux paste-buffer (delivery)
```

## Modifying Agents

Edit files in `agents/`. Each agent has:
- **Role**: what they do
- **Constraints**: what they cannot do
- **Skills**: superpowers skills they must invoke
- **Workflow**: step-by-step process
- **Message behavior**: how to react to incoming messages

Agent system prompts are dynamically augmented at launch with:
- Team roster (from `team_roster.md`)
- Session info (session name, project dir, agent name)
- Language setting (from `--lang` flag)

## Testing Changes

```bash
team-stop                    # Stop current session
team-start .                 # Restart with updated definitions
tmux attach -t team-<name>   # Verify agents behave correctly
```
