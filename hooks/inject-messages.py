#!/usr/bin/env python3
"""UserPromptSubmit hook: inject unread messages into agent prompt.

Fallback mechanism for messages that arrived while the agent was busy.
Primary delivery is via tmux send-keys in the MCP server.

Reads stdin (user input), prepends any unread messages, writes to stdout.
"""

import os
import sqlite3
import sys
from pathlib import Path


def main() -> None:
    user_input = sys.stdin.read()

    agent_name = os.environ.get("TEAM_AGENT_NAME")
    if not agent_name:
        # Not in team mode, pass through unchanged
        sys.stdout.write(user_input)
        return

    # Read session name: prefer file, fallback to env
    session_file = Path.cwd() / ".team" / "session_name"
    if session_file.exists():
        session = session_file.read_text().strip()
    else:
        session = os.environ.get("TEAM_TMUX_SESSION", "")
    db_path = os.environ.get(
        "TEAM_DB_PATH",
        str(Path.home() / ".claude" / "team" / "mcp-server" / "team.db"),
    )

    if not Path(db_path).exists():
        sys.stdout.write(user_input)
        return

    try:
        conn = sqlite3.connect(db_path)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout = 2000")

        rows = conn.execute(
            "SELECT * FROM messages WHERE session = ? AND to_agent = ? AND read = 0 ORDER BY created_at ASC",
            (session, agent_name),
        ).fetchall()

        if not rows:
            sys.stdout.write(user_input)
            conn.close()
            return

        # Format unread messages
        lines = [f"[{len(rows)} unread message(s)]\n"]
        ids = []
        for row in rows:
            msg = dict(row)
            priority_tag = (
                f" [{msg['priority'].upper()}]" if msg["priority"] != "normal" else ""
            )
            lines.append(f"From: {msg['from_agent']}{priority_tag}")
            lines.append(f"Subject: {msg['subject']}")
            lines.append(msg["body"])
            lines.append(f"(id: {msg['id']})")
            lines.append("")
            ids.append(msg["id"])

        lines.append("---\n")

        # Mark as read
        for msg_id in ids:
            conn.execute("UPDATE messages SET read = 1 WHERE id = ?", (msg_id,))
        conn.commit()
        conn.close()

        # Prepend messages to user input
        sys.stdout.write("".join(line + "\n" for line in lines) + user_input)

    except Exception:
        # On any error, pass through unchanged — don't break the user's input
        sys.stdout.write(user_input)


if __name__ == "__main__":
    main()
