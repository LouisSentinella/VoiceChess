"""Mistake log: when the listener loses track of the board.

Two signals, both recorded automatically: a spoken move that clearly names a piece
and a square but is not legal, and every "where is / what is on / what is attacking"
question. Kept in a small SQLite file so it survives restarts and later feeds drills.
"""

from __future__ import annotations

import os
import sqlite3
import time
from collections import Counter
from pathlib import Path

import chess

SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    time TEXT NOT NULL,
    game TEXT NOT NULL,
    ply INTEGER NOT NULL,
    kind TEXT NOT NULL,       -- illegal_attempt | lookup
    piece TEXT,               -- knight, bishop, ...
    square TEXT,              -- e5
    detail TEXT NOT NULL
)
"""


def default_path() -> Path:
    base = os.environ.get("VOICECHESS_DATA_DIR") or Path.home() / ".local" / "share" / "voicechess"
    return Path(base) / "mistakes.db"


class MistakeLog:
    def __init__(self, path: Path | None = None):
        path = path or default_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        # One connection, used from the event loop thread only.
        self.db = sqlite3.connect(path)
        self.db.execute(SCHEMA)
        self.db.commit()

    def close(self) -> None:
        self.db.close()

    def record(
        self,
        kind: str,
        game: str,
        ply: int,
        detail: str,
        piece: int | None = None,
        square: int | None = None,
    ) -> None:
        self.db.execute(
            "INSERT INTO events (time, game, ply, kind, piece, square, detail) VALUES (?,?,?,?,?,?,?)",
            (
                time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                game,
                ply,
                kind,
                chess.piece_name(piece) if piece else None,
                chess.square_name(square) if square is not None else None,
                detail,
            ),
        )
        self.db.commit()

    def summary(self) -> dict:
        rows = self.db.execute("SELECT kind, piece, square FROM events").fetchall()
        illegal = sum(1 for k, _, _ in rows if k == "illegal_attempt")
        lookups = len(rows) - illegal
        by_piece = Counter(p for _, p, _ in rows if p)
        by_square = Counter(s for _, _, s in rows if s)
        recent = [
            {"time": t, "kind": k, "detail": d, "game": g}
            for t, k, d, g in self.db.execute(
                "SELECT time, kind, detail, game FROM events ORDER BY id DESC LIMIT 10"
            )
        ]
        return {
            "illegal_attempts": illegal,
            "lookups": lookups,
            "by_piece": dict(by_piece.most_common()),
            "by_square": dict(by_square.most_common(8)),
            "spoken": spoken_summary(illegal, lookups, by_piece),
            "recent": recent,
        }


def spoken_summary(illegal: int, lookups: int, by_piece: Counter) -> str:
    if illegal == 0 and lookups == 0:
        return "Your mistake log is empty."
    parts = []
    if lookups:
        parts.append(f"asked about the board {lookups} time{'s' if lookups != 1 else ''}")
    if illegal:
        parts.append(f"tried {illegal} illegal move{'s' if illegal != 1 else ''}")
    text = "You " + " and ".join(parts) + "."
    if by_piece:
        text += f" The piece you lose track of most is the {by_piece.most_common(1)[0][0]}."
    return text
