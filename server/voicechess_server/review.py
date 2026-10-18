"""Post-game review: the listener's own worst moves, by engine loss.

Positions are normally already analysed (the server warms the cache after every ply),
so this is mostly cache hits.
"""

from __future__ import annotations

import chess

from .analysis import MATE_CP, Analyzer, pov_cp
from .facts import move_label
from .game import Game
from . import spoken

MIN_LOSS_CP = 100
MAX_MOMENTS = 5


def listener_plies(game: Game) -> list[int]:
    """1-based plies of the listener's own moves."""
    first = 1 if game.player == chess.WHITE else 2
    return list(range(first, len(game.board.move_stack) + 1, 2))


def position_after(game: Game, ply: int) -> chess.Board:
    board = game.board.copy()
    while len(board.move_stack) > ply:
        board.pop()
    return board


async def review(game: Game, analyzer: Analyzer) -> dict:
    moves_played = len(listener_plies(game))
    if not analyzer.available():
        return {"summary": "I can't review right now: the engine is not available.", "moments": []}

    moments = []
    for ply in listener_plies(game):
        after = position_after(game, ply)
        move = after.peek()
        before = after.copy()
        before.pop()
        best_lines = await analyzer.lines(before, 1)
        if not best_lines:
            continue
        best = best_lines[0]
        if after.is_checkmate():
            after_cp = MATE_CP
        else:
            after_lines = await analyzer.lines(after, 1)
            after_cp = pov_cp(after_lines[0], game.player) if after_lines else 0
        before_cp = pov_cp(best, game.player)
        loss = before_cp - after_cp
        if loss < MIN_LOSS_CP or move == best.first:
            continue
        moments.append({
            "ply": ply,
            "move_number": (ply + 1) // 2,
            "san": before.san(move),
            "uci": move.uci(),
            "spoken": spoken.speak_move(before, move),
            "best_san": before.san(best.first),
            "best_spoken": spoken.speak_move(before, best.first),
            "loss_pawns": round(min(loss, MATE_CP) / 100, 1),
            "label": move_label(loss),
            "fen_before": before.fen(),
            "fen_after": after.fen(),
        })

    moments.sort(key=lambda m: -m["loss_pawns"])
    moments = moments[:MAX_MOMENTS]
    return {"summary": _summary(moves_played, moments), "moments": moments}


def _summary(moves_played: int, moments: list[dict]) -> str:
    if moves_played == 0:
        return "You have not played any moves yet."
    if not moments:
        return f"You played {moves_played} move{'s' if moves_played != 1 else ''} and I found no mistakes worth reviewing."
    blunders = sum(1 for m in moments if m["label"] == "a blunder")
    others = len(moments) - blunders
    bits = []
    if blunders:
        bits.append(f"{blunders} blunder{'s' if blunders != 1 else ''}")
    if others:
        bits.append(f"{others} other mistake{'s' if others != 1 else ''}")
    return (f"You played {moves_played} move{'s' if moves_played != 1 else ''}: {' and '.join(bits)}. "
            "Let's go through them.")


def moment_game(game: Game, ply: int) -> Game:
    """A copy of the game as it stood just after the given ply, for explaining that move."""
    clone = Game(game.id, game.player, game.opponent)
    clone.board = position_after(game, ply)
    return clone
