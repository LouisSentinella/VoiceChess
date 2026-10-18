"""Full-strength Stockfish analysis, cached per position. Separate from the opponent engines."""

from __future__ import annotations

import asyncio
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path

import chess
import chess.engine

MATE_CP = 100_000
CACHE_SIZE = 256


@dataclass(frozen=True)
class Line:
    cp: int  # centipawns from White's point of view; a forced mate is +-MATE_CP minus plies
    mate: int | None  # moves to mate, positive when White mates; None if not a forced mate
    first: chess.Move
    san: tuple[str, ...]  # the principal variation, a few plies


def pov_cp(line: Line, color: chess.Color) -> int:
    return line.cp if color == chess.WHITE else -line.cp


class Analyzer:
    def __init__(self, path: Path, threads: int = 2, hash_mb: int = 128, seconds: float = 0.5):
        self.path, self.threads, self.hash_mb, self.seconds = path, threads, hash_mb, seconds
        self._engine: chess.engine.UciProtocol | None = None
        self._lock = asyncio.Lock()
        self._cache: OrderedDict[str, list[Line]] = OrderedDict()

    def available(self) -> bool:
        return self.path.exists()

    async def close(self) -> None:
        if self._engine is not None:
            await self._engine.quit()
            self._engine = None

    async def lines(self, board: chess.Board, multipv: int = 1) -> list[Line]:
        """Best lines for this position, best first. Empty if the game is over."""
        if board.is_game_over(claim_draw=True):
            return []
        key = board.fen()
        cached = self._cache.get(key)
        if cached is not None and len(cached) >= min(multipv, board.legal_moves.count()):
            self._cache.move_to_end(key)
            return cached[:multipv]

        async with self._lock:
            if self._engine is None:
                _, self._engine = await chess.engine.popen_uci(str(self.path))
                await self._engine.configure({"Threads": self.threads, "Hash": self.hash_mb})
            root = board.copy(stack=False)  # the analysis does not need the history
            infos = await self._engine.analyse(
                root, chess.engine.Limit(time=self.seconds), multipv=multipv
            )

        result = []
        for info in infos:
            pv = info.get("pv") or []
            if not pv:
                continue
            score = info["score"].white()
            result.append(
                Line(
                    cp=score.score(mate_score=MATE_CP),
                    mate=score.mate(),
                    first=pv[0],
                    san=tuple(_san_line(root, pv[:6])),
                )
            )
        self._cache[key] = result
        if len(self._cache) > CACHE_SIZE:
            self._cache.popitem(last=False)
        return result


def _san_line(board: chess.Board, moves: list[chess.Move]) -> list[str]:
    out = []
    b = board.copy(stack=False)
    for m in moves:
        out.append(b.san(m))
        b.push(m)
    return out
