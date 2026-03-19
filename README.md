# Claude Team

> Turn one Claude into a whole dev team.

Launch a team of specialized AI agents — leader, planner, developer, reviewer, and more — each running as an independent [Claude Code](https://docs.anthropic.com/en/docs/claude-code) session. They collaborate autonomously through a message bus, just like a real engineering team.

```
┌─────────────┬─────────────┬─────────────┬─────────────┐
│ Ada         │ Bob         │ Dan         │ Fox         │
│ (leader)    │ (planner)   │ (developer) │ (reviewer)  │
│             │             │             │             │
│ Understands │ Designs the │ Writes the  │ Reviews the │
│ the goal,   │ plan, picks │ code, runs  │ code, finds │
│ delegates   │ the approach│ tests       │ issues      │
└─────────────┴─────────────┴─────────────┴─────────────┘
  Talk to Ada. She handles the rest.
```

## Why?

A single Claude Code session does everything: plan, code, review, test. It works, but context gets bloated and quality drops on complex tasks.

Claude Team splits the work across **focused agents**, each with a clean context window and a clear job. The leader coordinates. You just describe what you want.

## Quick Start

```bash
# Install
git clone https://github.com/Sy1vainM/claude-team.git
cd claude-team
./scripts/install.sh

# Start a team in your project
cd /path/to/your/project
team-start --yolo .

# Enter the team
tmux attach -t team-<dirname>
```

Talk to Ada (pane 0). Tell her what to build. Watch the team work.

## Features

- **Preset teams** — default (4), minimal (2), research (5), or full (8) agents
- **Custom configs** — define your own team composition with `team.yaml`
- **Dynamic scaling** — add or remove agents at runtime without restarting
- **Session resume** — stop and restart preserves every agent's full conversation history
- **Auto-naming** — agents get human names (Ada, Bob, Cat, Dan...) from a 20-name pool
- **Smart layout** — tmux panes auto-arrange: 1 row for ≤4, 2 rows for 5-8, 3 rows for 9
- **Multi-language** — `--lang Chinese` (or any language) for agent communication
- **Multi-project** — run separate teams for different projects simultaneously
- **MCP messaging** — agents communicate via SQLite-backed message bus, delivered automatically

## Usage

### Start

```bash
team-start .                            # Default: Ada + Bob + Dan + Fox
team-start --preset research .          # + Cat the researcher
team-start --preset full .              # All 8 roles
team-start --yolo --lang Chinese .      # Autonomous + Chinese
team-start --config .team/team.yaml .   # Custom team config
```

Or inside Claude Code: `/team start`

### Scale

```bash
team-add tester                         # Adds Gil (tester) to running team
team-add developer --name Eve           # Another developer named Eve
team-remove Fox                         # Remove Fox, preserves session for re-add
team-add Fox                            # Bring Fox back with full context
```

### Stop & Resume

```bash
team-stop                               # Stop (agents resumable)
team-start .                            # Resume — full context restored
team-stop --clean                       # Stop and wipe (fresh start next time)
```

### Navigate

| Shortcut | Action |
|----------|--------|
| `Ctrl+B q N` | Jump to pane N |
| `Ctrl+B z` | Zoom/unzoom pane |
| `Ctrl+B d` | Detach (agents keep running) |

## How It Works

```
You ── talk to Ada ── Ada delegates ── agents work ── results
         │                                    ▲
         │         ┌──────────────────────────┘
         ▼         │
    ┌─────────────────────────────────┐
    │  MCP Message Bus (SQLite)       │
    │  send_message / broadcast /     │
    │  check_messages / reply         │
    └─────────────────────────────────┘
         │              │
    tmux pane 0    tmux pane 1   ...
    (Ada)          (Bob)
```

Each agent is a full Claude Code session with:
- **Role-specific system prompt** defining identity, constraints, and workflow
- **Team roster** so they know who to message
- **Session info** so commands like `team-add` target the right team
- **Language setting** overriding personal config

## Team Presets

| Preset | Agents | Best For |
|--------|--------|----------|
| `default` | Ada (leader), Bob (planner), Dan (developer), Fox (reviewer) | Standard dev |
| `minimal` | Ada (leader), Dan (developer) | Quick tasks |
| `research` | + Cat (researcher) | Research-first dev |
| `full` | + Eve (dev-fast), Gil (tester), Hal (writer) | Full pipeline |

## Custom Team

```yaml
# .team/team.yaml
team:
  - role: leader
    name: Ada
  - role: developer
    name: backend-dev
    model: claude-opus-4-6
  - role: developer
    name: frontend-dev
    model: claude-sonnet-4-6
  - role: reviewer
    name: Fox
```

## Agent Roles

| Role | What They Do | Output |
|------|-------------|--------|
| **leader** | Coordinates the team, delegates tasks, makes decisions | — |
| **planner** | Designs the solution, writes implementation plan | `.team/PLAN.md` |
| **researcher** | Finds existing solutions, compares approaches | `.team/RESEARCH.md` |
| **developer** | Implements the plan, writes production code | Source code |
| **developer-fast** | Quick tasks: config, boilerplate, small fixes | Source code |
| **reviewer** | Reviews code quality + plan compliance | `.team/REVIEW.md` |
| **tester** | Writes and runs tests | `.team/TEST_REPORT.md` |
| **writer** | Documentation, reports, changelogs | `.team/SUMMARY.md` |

All roles are customizable — edit `agents/*.md` to change behavior.

## Typical Workflow

```
You:  "Build a REST API for user authentication with JWT"
       │
Ada:   Breaks it down, sends to Bob
       │
Bob:   Writes PLAN.md, notifies Dan + Fox
       │
Dan:   Implements the code following the plan
       │
Fox:   Reviews code against the plan, sends feedback
       │
Dan:   Fixes issues
       │
Ada:   "Done. Here's what was built: ..."
```

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)
- tmux
- Python 3.12+ (auto-managed by [uv](https://docs.astral.sh/uv/))

## Install / Uninstall

```bash
# Install
git clone https://github.com/Sy1vainM/claude-team.git
cd claude-team
./scripts/install.sh

# Uninstall
~/.claude/team/scripts/uninstall.sh
```

The installer sets up: Python venv, CLI commands (`team-start/stop/status/add/remove`), MCP server, message hook, and the `/team` skill for Claude Code.

## License

MIT
