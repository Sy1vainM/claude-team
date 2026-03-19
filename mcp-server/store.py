"""SQLite-backed message store for inter-agent communication."""

import secrets
import sqlite3
import string
from datetime import datetime, timezone


def random_id(length: int = 12) -> str:
    """Generate a random alphanumeric ID."""
    alphabet = string.ascii_lowercase + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def init_db(db_path: str) -> sqlite3.Connection:
    """Initialize SQLite database with WAL mode and message schema."""
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA synchronous = NORMAL")
    conn.execute("PRAGMA busy_timeout = 5000")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS messages (
            id          TEXT PRIMARY KEY,
            session     TEXT NOT NULL DEFAULT '',
            from_agent  TEXT NOT NULL,
            to_agent    TEXT NOT NULL,
            subject     TEXT NOT NULL,
            body        TEXT NOT NULL,
            thread_id   TEXT,
            priority    TEXT DEFAULT 'normal'
                        CHECK(priority IN ('low', 'normal', 'high')),
            read        INTEGER DEFAULT 0,
            created_at  TEXT NOT NULL
        )
    """)
    # Migrate: add session column if table existed before this change
    try:
        conn.execute("ALTER TABLE messages ADD COLUMN session TEXT NOT NULL DEFAULT ''")
        conn.commit()
    except sqlite3.OperationalError:
        pass  # Column already exists
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_inbox ON messages(session, to_agent, read)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_thread ON messages(thread_id)"
    )
    conn.commit()
    return conn


def insert_message(
    conn: sqlite3.Connection,
    session: str,
    from_agent: str,
    to_agent: str,
    subject: str,
    body: str,
    priority: str = "normal",
    thread_id: str | None = None,
) -> dict:
    """Insert a message and return it as a dict."""
    msg_id = f"msg-{random_id()}"
    now = datetime.now(timezone.utc).isoformat()
    conn.execute(
        """
        INSERT INTO messages (id, session, from_agent, to_agent, subject, body,
                              priority, thread_id, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (msg_id, session, from_agent, to_agent, subject, body, priority, thread_id, now),
    )
    conn.commit()
    return {
        "id": msg_id,
        "session": session,
        "from": from_agent,
        "to": to_agent,
        "subject": subject,
        "body": body,
        "priority": priority,
        "thread_id": thread_id,
        "read": False,
        "created_at": now,
    }


def get_unread(conn: sqlite3.Connection, session: str, agent_name: str) -> list[dict]:
    """Get all unread messages for an agent in a session."""
    rows = conn.execute(
        """
        SELECT * FROM messages
        WHERE session = ? AND to_agent = ? AND read = 0
        ORDER BY created_at ASC
        """,
        (session, agent_name),
    ).fetchall()
    return [dict(row) for row in rows]


def mark_read(conn: sqlite3.Connection, message_id: str) -> None:
    """Mark a message as read."""
    conn.execute("UPDATE messages SET read = 1 WHERE id = ?", (message_id,))
    conn.commit()


def mark_all_read(conn: sqlite3.Connection, session: str, agent_name: str) -> int:
    """Mark all unread messages for an agent in a session as read. Returns count."""
    cursor = conn.execute(
        "UPDATE messages SET read = 1 WHERE session = ? AND to_agent = ? AND read = 0",
        (session, agent_name),
    )
    conn.commit()
    return cursor.rowcount


def get_thread(conn: sqlite3.Connection, thread_id: str) -> list[dict]:
    """Get all messages in a thread, ordered by time."""
    rows = conn.execute(
        """
        SELECT * FROM messages
        WHERE thread_id = ?
        ORDER BY created_at ASC
        """,
        (thread_id,),
    ).fetchall()
    return [dict(row) for row in rows]


def get_recent(conn: sqlite3.Connection, session: str, limit: int = 20) -> list[dict]:
    """Get recent messages in a session."""
    rows = conn.execute(
        """
        SELECT * FROM messages
        WHERE session = ?
        ORDER BY created_at DESC
        LIMIT ?
        """,
        (session, limit),
    ).fetchall()
    return [dict(row) for row in rows]


def get_by_id(conn: sqlite3.Connection, message_id: str) -> dict | None:
    """Get a single message by ID."""
    row = conn.execute(
        "SELECT * FROM messages WHERE id = ?", (message_id,)
    ).fetchone()
    return dict(row) if row else None
