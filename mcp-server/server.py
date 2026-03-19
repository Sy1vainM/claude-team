"""MCP server for inter-agent team messaging.

Provides tools for sending, receiving, and replying to messages
between Claude Code agents running in tmux panes.
"""

import json
import logging
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from mcp.server.fastmcp import FastMCP

from store import get_by_id, get_recent, get_unread, init_db, insert_message, mark_read, mark_all_read

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stderr,
)
logger = logging.getLogger("team-mail")

# --- Configuration ---

AGENT_NAME = os.environ.get("TEAM_AGENT_NAME", "unknown")
DB_PATH = os.environ.get(
    "TEAM_DB_PATH",
    str(Path.home() / ".claude" / "team" / "mcp-server" / "team.db"),
)
# Read session name: prefer file (reliable), fallback to env, then default
_session_file = Path.cwd() / ".team" / "session_name"
if _session_file.exists():
    TMUX_SESSION = _session_file.read_text().strip()
else:
    TMUX_SESSION = os.environ.get("TEAM_TMUX_SESSION", "team")

# Read agent-to-pane mapping from roster.json (written by team-start.sh)
_roster_file = Path.cwd() / ".team" / "roster.json"

def _load_roster() -> tuple[dict[str, int], list[str]]:
    """Load agent-to-pane mapping from roster.json."""
    if _roster_file.exists():
        panes = json.loads(_roster_file.read_text())
        logger.info("Loaded roster: %s", panes)
    else:
        panes = {"planner": 0, "developer": 1, "reviewer": 2, "tester": 3}
        logger.warning("No roster.json found, using legacy pane mapping")
    return panes, list(panes.keys())

AGENT_PANES, ALL_AGENTS = _load_roster()

# --- Database ---

db = init_db(DB_PATH)
logger.info("Agent=%s DB=%s Tmux=%s", AGENT_NAME, DB_PATH, TMUX_SESSION)

# --- MCP Server ---

mcp = FastMCP("team-mail")


def _deliver_via_tmux(to_agent: str, formatted_msg: str) -> None:
    """Deliver a message by sending keys to the target agent's tmux pane."""
    pane_index = AGENT_PANES.get(to_agent)
    if pane_index is None:
        logger.warning("Unknown agent %s, skipping tmux delivery", to_agent)
        return

    target = f"{TMUX_SESSION}.{pane_index}"

    # Check if tmux session exists
    result = subprocess.run(
        ["tmux", "has-session", "-t", TMUX_SESSION],
        capture_output=True,
    )
    if result.returncode != 0:
        logger.warning("Tmux session %s not found, skipping delivery", TMUX_SESSION)
        return

    # Check if agent is idle (at prompt). If busy, skip — hook will catch it.
    pane_content = subprocess.run(
        ["tmux", "capture-pane", "-t", target, "-p"],
        capture_output=True, text=True,
    )
    last_lines = pane_content.stdout.strip().split("\n")[-3:]
    is_idle = any("❯" in line or "⏵" in line for line in last_lines)
    if not is_idle:
        logger.info("Agent %s is busy, message queued in DB (hook will deliver)", to_agent)
        return

    # Use load-buffer + paste-buffer to avoid send-keys escaping issues
    buf_name = f"team-msg-{to_agent}"
    with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
        f.write(formatted_msg)
        tmp_path = f.name

    try:
        subprocess.run(
            ["tmux", "load-buffer", "-b", buf_name, tmp_path],
            capture_output=True,
        )
        subprocess.run(
            ["tmux", "paste-buffer", "-b", buf_name, "-t", target],
            capture_output=True,
        )
        # Send Enter separately via send-keys to submit the pasted message.
        # Use a small delay to ensure paste completes before Enter is sent.
        time.sleep(0.2)
        subprocess.run(
            ["tmux", "send-keys", "-t", target, "Enter"],
            capture_output=True,
        )
        subprocess.run(
            ["tmux", "delete-buffer", "-b", buf_name],
            capture_output=True,
        )
    finally:
        Path(tmp_path).unlink(missing_ok=True)

    logger.info("Delivered to %s (pane %d)", to_agent, pane_index)


def _format_for_delivery(from_agent: str, subject: str, body: str, priority: str, msg_id: str) -> str:
    """Format a message for tmux send-keys delivery."""
    priority_tag = f" [{priority.upper()}]" if priority != "normal" else ""
    return (
        f"[Message from {from_agent}{priority_tag}] "
        f"{subject}: {body}\n"
        f"(Reply with: reply(\"{msg_id}\", \"your response\"))"
    )


@mcp.tool()
def send_message(
    to: str,
    subject: str,
    body: str,
    priority: str = "normal",
) -> str:
    """Send a message to another agent.

    Args:
        to: Target agent name (from current team roster)
        subject: Brief subject line
        body: Message content
        priority: Message priority (low, normal, high)
    """
    global AGENT_PANES, ALL_AGENTS
    if to not in ALL_AGENTS:
        # Reload roster in case a new agent was added at runtime
        AGENT_PANES, ALL_AGENTS = _load_roster()
    if to not in ALL_AGENTS:
        return f"Error: Unknown agent '{to}'. Valid agents: {', '.join(ALL_AGENTS)}"

    if to == AGENT_NAME:
        return "Error: Cannot send message to yourself"

    msg = insert_message(db, TMUX_SESSION, AGENT_NAME, to, subject, body, priority)

    formatted = _format_for_delivery(AGENT_NAME, subject, body, priority, msg["id"])
    _deliver_via_tmux(to, formatted)

    return f"Message sent to {to} (id: {msg['id']})"


@mcp.tool()
def broadcast(subject: str, body: str) -> str:
    """Send a message to all other agents.

    Args:
        subject: Brief subject line
        body: Message content
    """
    global AGENT_PANES, ALL_AGENTS
    # Reload roster to include any agents added at runtime
    AGENT_PANES, ALL_AGENTS = _load_roster()
    recipients = [a for a in ALL_AGENTS if a != AGENT_NAME]
    ids = []

    for agent in recipients:
        msg = insert_message(db, TMUX_SESSION, AGENT_NAME, agent, subject, body)
        ids.append(msg["id"])

        formatted = _format_for_delivery(AGENT_NAME, subject, body, "normal", msg["id"])
        _deliver_via_tmux(agent, formatted)

    return f"Broadcast sent to {', '.join(recipients)} (ids: {', '.join(ids)})"


@mcp.tool()
def check_messages() -> str:
    """Check unread messages for the current agent."""
    messages = get_unread(db, TMUX_SESSION, AGENT_NAME)

    if not messages:
        return "No unread messages."

    lines = [f"You have {len(messages)} unread message(s):\n"]
    for msg in messages:
        priority_tag = (
            f" [{msg['priority'].upper()}]" if msg["priority"] != "normal" else ""
        )
        lines.append(f"--- From: {msg['from_agent']}{priority_tag} ---")
        lines.append(f"Subject: {msg['subject']}")
        lines.append(msg["body"])
        lines.append(f"ID: {msg['id']}  |  reply('{msg['id']}', 'your reply')")
        lines.append("")

        mark_read(db, msg["id"])

    return "\n".join(lines)


@mcp.tool()
def list_threads(limit: int = 20) -> str:
    """List recent messages across all agents.

    Args:
        limit: Maximum number of messages to return (default 20)
    """
    messages = get_recent(db, TMUX_SESSION, limit)

    if not messages:
        return "No messages yet."

    lines = [f"Recent messages (last {limit}):\n"]
    for msg in messages:
        read_mark = " " if msg["read"] else "*"
        lines.append(
            f"[{read_mark}] {msg['from_agent']} → {msg['to_agent']}: "
            f"{msg['subject']} ({msg['created_at'][:16]})"
        )

    return "\n".join(lines)


@mcp.tool()
def reply(message_id: str, body: str) -> str:
    """Reply to a message, maintaining the conversation thread.

    Args:
        message_id: ID of the message to reply to
        body: Reply content
    """
    original = get_by_id(db, message_id)
    if not original:
        return f"Error: Message '{message_id}' not found"

    thread_id = original["thread_id"] or original["id"]
    to_agent = (
        original["to_agent"]
        if original["from_agent"] == AGENT_NAME
        else original["from_agent"]
    )

    msg = insert_message(
        db,
        TMUX_SESSION,
        AGENT_NAME,
        to_agent,
        f"Re: {original['subject']}",
        body,
        thread_id=thread_id,
    )

    formatted = _format_for_delivery(
        AGENT_NAME, f"Re: {original['subject']}", body, "normal", msg["id"]
    )
    _deliver_via_tmux(to_agent, formatted)

    return f"Reply sent to {to_agent} (id: {msg['id']}, thread: {thread_id})"


if __name__ == "__main__":
    mcp.run(transport="stdio")
