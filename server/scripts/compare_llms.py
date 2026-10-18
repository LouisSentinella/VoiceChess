"""Run the same coach questions through several OpenRouter models and print answers and latency.

    cd server && uv run python scripts/compare_llms.py [model ...]

Reads OPENROUTER_API_KEY from the environment or ~/.config/voicechess/env. Costs a few cents.
"""

from __future__ import annotations

import asyncio
import os
import sys
import time
from pathlib import Path

import chess

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from voicechess_server import coach  # noqa: E402
from voicechess_server.analysis import Analyzer  # noqa: E402
from voicechess_server.facts import build_facts  # noqa: E402
from voicechess_server.game import Game, OpponentSpec  # noqa: E402
from voicechess_server.llm import OPENROUTER_URL, Backend, LlmClient, LlmError  # noqa: E402

DEFAULT_MODELS = [
    "anthropic/claude-haiku-5.5",
    "deepseek/deepseek-v4.1-flash-1017",
    "deepseek/deepseek-v4.1-flash",
    "google/gemini-3.1-flash-lite",
    "anthropic/claude-sonnet-5.5",  # quality ceiling
]

# (name, moves played by white and black alternately, questions). The listener is White.
SCENARIOS = [
    (
        "Hung the queen",
        "e4 e5 Qh5 Nc6 Qxf7+ Kxf7",
        ["why was that a mistake", "what should I do now", "am I winning"],
    ),
    (
        "Fried Liver chance",
        "e4 e5 Nf3 Nc6 Bc4 Nf6 Ng5 d5 exd5 Nxd5",
        ["what is my best move here", "what should I be worried about", "why does that work"],
    ),
    (
        "Quiet opening",
        "d4 d5 c4 e6 Nc3 Nf6",
        ["what is my plan", "is my position okay"],
    ),
]


def load_key() -> str:
    if key := os.environ.get("OPENROUTER_API_KEY"):
        return key
    env = Path.home() / ".config" / "voicechess" / "env"
    if env.exists():
        for line in env.read_text().splitlines():
            if line.startswith("OPENROUTER_API_KEY="):
                return line.split("=", 1)[1].strip().strip("'\"")
    sys.exit("No OPENROUTER_API_KEY in the environment or ~/.config/voicechess/env")


async def main(models: list[str]) -> None:
    key = load_key()
    stockfish = Path(__file__).resolve().parent.parent / "engines" / "bin" / "stockfish"
    analyzer = Analyzer(stockfish)
    try:
        for title, moves, questions in SCENARIOS:
            game = Game("cmp", chess.WHITE, OpponentSpec("maia", 1500))
            for san in moves.split():
                game.board.push_san(san)
            facts = await build_facts(game, analyzer)
            print(f"\n{'=' * 78}\n{title}: {moves}\n{'=' * 78}")
            for question in questions:
                print(f"\nQ: {question}")
                for model in models:
                    backend = Backend("openrouter", OPENROUTER_URL, model, key,
                                      extra_body={"reasoning": {"enabled": False}})
                    llm = LlmClient([backend])
                    started = time.perf_counter()
                    first = None
                    spoken: list[str] = []
                    try:
                        async for s in coach.sentences(llm.stream(coach._messages(game, question, facts))):
                            first = first or time.perf_counter() - started
                            spoken.append(s)
                    except LlmError as e:
                        spoken.append(f"[error: {e}]")
                    finally:
                        await llm.close()
                    total = time.perf_counter() - started
                    first_s = f"{first:.1f}s" if first else "-"
                    print(f"  {model}  (first {first_s}, total {total:.1f}s)")
                    for s in spoken:
                        print(f"    {s}")
    finally:
        await analyzer.close()


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1:] or DEFAULT_MODELS))
