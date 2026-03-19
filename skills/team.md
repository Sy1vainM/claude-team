---
description: Manage multi-agent team - start, stop, add/remove agents, resume sessions in tmux
user-invocable: true
---

# Team Skill

Manage the multi-agent Claude Code team (configurable agents running in tmux panes).

Commands: `team-start`, `team-stop`, `team-status`, `team-add`, `team-remove`.

## Key Concepts

- **Presets**: predefined team compositions (default, minimal, research, full)
- **Custom config**: `team.yaml` with roles, custom names, and model overrides
- **Multiple developers**: use `--name` to give unique names (e.g. `dev-core`, `dev-ui`)
- **Dynamic scaling**: add/remove agents at runtime without restarting the team
- **Resume**: stop and restart preserves each agent's full conversation context

## Commands

Parse user intent from `$ARGUMENTS` and run the matching command.

### 1. Start Team (`/team start`, `/team`, `/team start /path/to/project`)

Start a new team session for a project. On restart, automatically resumes previous agents and their conversation context.

Flags:
- `--yolo`: skip permission prompts for all agents
- `--preset NAME`: use a preset team (default, research, minimal, full)
- `--config FILE`: use a custom team.yaml
- `--lang LANG`: agent communication language (default: English)

Presets:
- `default`: leader + planner + developer + reviewer
- `minimal`: leader + developer
- `research`: default + researcher
- `full`: leader + researcher + planner + dev-core + dev-fast + reviewer + tester + writer

Custom team.yaml example (multiple developers with different models):
```yaml
team:
  - role: leader
  - role: developer
    name: dev-backend
    model: claude-opus-4-6
  - role: developer
    name: dev-frontend
    model: claude-sonnet-4-6
  - role: reviewer
```

1. Determine the project directory:
   - If user provides a path → use it
   - If no path → use the current working directory
2. **Choose team composition** — if user didn't specify `--preset` or `--config`, choose the best starting preset based on the task context. **Start lean** — agents can be added dynamically later via `team-add`, so prefer fewer roles upfront for the planning phase:
   - Most tasks → `minimal` (leader + developer) — start here, add roles as the plan demands
   - Tasks needing upfront design → `default` (leader + planner + developer + reviewer)
   - Tasks needing research/exploration first → `research` (default + researcher)
   - Only use `full` if the user explicitly asks for it or the task clearly needs all roles from the start
   - Briefly explain your choice and remind the user that more agents can be added anytime.
3. **Recommend `--yolo` mode by default** — ask the user: "Recommended: start with `--yolo` (autonomous mode, agents skip permission prompts). Proceed with `--yolo`?" If user agrees, add `--yolo`. If user declines, start without it.
4. Build the command: `team-start [flags] <project-dir>`
4. Wait for the script to complete, then display:
   - Session name and agent list
   - How to attach: `tmux attach -t <session-name>`
   - Pane navigation shortcuts (Ctrl+B q, Ctrl+B z, Ctrl+B d)

### 2. Stop Team (`/team stop`, `/team stop <session-name>`)

Stop a running team session. Agents are resumable by default.

1. If user provides a session name → `team-stop <session-name>`
2. If no name → `team-stop` (auto-detects if only one session)
3. If user wants a clean stop (no resume) → `team-stop --clean <session-name>`
4. Confirm the session was stopped

### 3. Check Status (`/team status`)

Show status of running team sessions.

1. Run: `team-status`
2. Display the output (active agents, unread message counts)

### 4. Add Agent (`/team add <role>`, `/team add developer --name dev-ui`)

Add an agent to a running team session without restarting.

1. Build the command: `team-add <role> [--name NAME] [--model MODEL] [--lang LANG] [--yolo] [--session SESSION]`
   - Role is required (e.g. reviewer, tester, researcher, developer)
   - `--name` for custom display name — auto-assigned from name pool if not specified
   - `--model` for specific Claude model
   - `--lang` for agent communication language
   - `--session` if multiple sessions are running
2. Run the command and display the result

### 5. Remove Agent (`/team remove <name>`, `/team remove dev-fast`)

Remove an agent from a running team session.

1. Build the command: `team-remove <agent-name> [--session SESSION]`
   - Uses agent name (display name), not role — important for multiple developers
2. Run the command and display the result
3. Note: leader cannot be removed. Session ID is preserved — `team-add` can bring them back with full context.

### 6. Help (`/team help`)

Show available commands and quick reference:

```
/team                            — Start team in current directory (default preset)
/team start [path]               — Start team for a project
/team start --preset research    — Start with research preset
/team start --yolo               — Start with autonomous agents
/team start --config team.yaml   — Start with custom config
/team add <role> [--name N]      — Add agent to running session
/team add developer --name dev-ui — Add another developer with custom name
/team remove <name>              — Remove agent (preserves session ID)
/team stop [name]                — Stop (agents resumable on next start)
/team stop --clean [name]        — Stop and clear all session state
/team status                     — Show running teams and message counts
/team help                       — Show this help
```

## Important Notes
- Each project gets its own tmux session named `team-<dirname>`
- Multiple teams can run simultaneously for different projects
- Agents keep running after you detach from tmux (Ctrl+B d)
- Stop + start on the same project = resume (agents keep their conversation history)
- `team-stop --clean` = fresh start next time (clears session IDs and saved config)

## Arguments
$ARGUMENTS
