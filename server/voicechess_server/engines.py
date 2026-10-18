"""UCI engine processes: Maia via lc0 and rating-limited Stockfish."""

from __future__ import annotations

import asyncio
import os
from dataclasses import dataclass
from pathlib import Path

import chess
import chess.engine

from .game import OpponentSpec

MAIA_LEVELS = range(1100, 2000, 100)
STOCKFISH_MOVE_TIME = 0.3  # seconds per move for the limited-strength opponent


class EngineError(Exception):
    pass


@dataclass(frozen=True)
class EngineConfig:
    engine_dir: Path

    @staticmethod
    def from_env() -> "EngineConfig":
        default = Path(__file__).resolve().parent.parent / "engines"
        return EngineConfig(Path(os.environ.get("VOICECHESS_ENGINE_DIR", default)))

    @property
    def lc0(self) -> Path:
        return self.engine_dir / "bin" / "lc0"

    @property
    def stockfish(self) -> Path:
        return self.engine_dir / "bin" / "stockfish"

    def maia_weights(self, level: int) -> Path:
        return self.engine_dir / "weights" / f"maia-{level}.pb.gz"


class _Engine:
    """One UCI process. The lock serialises commands; UCI is not concurrent."""

    def __init__(self, engine: chess.engine.UciProtocol):
        self.engine = engine
        self.lock = asyncio.Lock()


class EnginePool:
    def __init__(self, config: EngineConfig):
        self.config = config
        self._engines: dict[tuple[str, int], _Engine] = {}
        self._start_lock = asyncio.Lock()

    async def close(self) -> None:
        for e in self._engines.values():
            await e.engine.quit()
        self._engines.clear()

    async def prepare(self, spec: OpponentSpec) -> None:
        """Check the opponent is usable and start its engine, or raise EngineError."""
        if spec.type == "maia":
            if spec.level not in MAIA_LEVELS:
                raise EngineError(
                    f"Maia level must be one of {MAIA_LEVELS.start}-{MAIA_LEVELS.stop - 100} in steps of 100."
                )
            for path in (self.config.lc0, self.config.maia_weights(spec.level)):
                if not path.exists():
                    raise EngineError(f"Missing {path}. Run server/setup-engines.sh.")
        else:
            if not self.config.stockfish.exists():
                raise EngineError(f"Missing {self.config.stockfish}. Run server/setup-engines.sh.")
        await self._get(spec)

    async def _get(self, spec: OpponentSpec) -> _Engine:
        key = (spec.type, spec.level)
        async with self._start_lock:
            if key in self._engines:
                return self._engines[key]
            if spec.type == "maia":
                cmd = [
                    str(self.config.lc0),
                    f"--weights={self.config.maia_weights(spec.level)}",
                    "--backend=eigen",
                    "--threads=1",
                ]
                _, engine = await chess.engine.popen_uci(cmd)
            else:
                _, engine = await chess.engine.popen_uci(str(self.config.stockfish))
                elo = engine.options["UCI_Elo"]
                if not elo.min <= spec.level <= elo.max:
                    await engine.quit()
                    raise EngineError(f"Stockfish Elo must be {elo.min}-{elo.max}.")
                await engine.configure({"UCI_LimitStrength": True, "UCI_Elo": spec.level})
            wrapped = _Engine(engine)
            self._engines[key] = wrapped
            return wrapped

    async def choose_move(self, spec: OpponentSpec, board: chess.Board) -> chess.Move:
        engine = await self._get(spec)
        # Maia runs with no search: one node is the raw policy move, which is
        # what makes it miss tactics like a human of that rating.
        limit = (
            chess.engine.Limit(nodes=1)
            if spec.type == "maia"
            else chess.engine.Limit(time=STOCKFISH_MOVE_TIME)
        )
        async with engine.lock:
            result = await engine.engine.play(board, limit)
        if result.move is None:
            raise EngineError("Engine returned no move.")
        return result.move
