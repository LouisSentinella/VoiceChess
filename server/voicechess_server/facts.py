"""Facts about the position, computed by python-chess and Stockfish, for the language model.

The model only talks. Everything it is allowed to say about the board is in this text.
"""

from __future__ import annotations

import asyncio

import chess

from .analysis import MATE_CP, Analyzer, Line, pov_cp
from .game import Game

ANALYSIS_TIMEOUT = 8.0  # seconds to wait for engine facts before answering without them
VALUES = {chess.PAWN: 1, chess.KNIGHT: 3, chess.BISHOP: 3, chess.ROOK: 5, chess.QUEEN: 9}


def eval_words(cp: int) -> str:
    """Centipawns from the listener's point of view, in words, with the number."""
    pawns = abs(cp) / 100
    if abs(cp) >= MATE_CP - 1000:
        return "a forced mate for you" if cp > 0 else "a forced mate for me"
    if abs(cp) < 30:
        return "roughly equal (0.0)"
    side = "you" if cp > 0 else "me"
    strength = "slightly better" if abs(cp) < 80 else "clearly better" if abs(cp) < 200 \
        else "much better" if abs(cp) < 500 else "winning"
    return f"{strength} for {side} ({'+' if cp > 0 else '-'}{pawns:.1f})"


def move_label(loss_cp: int) -> str:
    if loss_cp <= 10:
        return "best or equal best"
    if loss_cp <= 50:
        return "good"
    if loss_cp <= 100:
        return "an inaccuracy"
    if loss_cp <= 300:
        return "a mistake"
    return "a blunder"


def _material(board: chess.Board, color: chess.Color) -> int:
    return sum(len(board.pieces(pt, color)) * v for pt, v in VALUES.items())


def _captured(board: chess.Board, player: chess.Color) -> str:
    start = {pt: n for pt, n in ((chess.PAWN, 8), (chess.KNIGHT, 2), (chess.BISHOP, 2), (chess.ROOK, 2), (chess.QUEEN, 1))}
    lost = {}
    for color in (chess.WHITE, chess.BLACK):
        lost[color] = [
            f"{start[pt] - len(board.pieces(pt, color))} {chess.piece_name(pt)}" + ("s" if start[pt] - len(board.pieces(pt, color)) > 1 else "")
            for pt in start
            if start[pt] - len(board.pieces(pt, color)) > 0
        ]
    return "Pieces captured so far: " + "; ".join(
        f"{'you have' if c == player else 'I have'} lost {', '.join(lost[c]) if lost[c] else 'nothing'}"
        for c in (player, not player)
    ) + "."


def _loose(board: chess.Board, color: chess.Color) -> list[str]:
    """Pieces of this colour that are attacked and either undefended or attacked by something cheaper."""
    out = []
    for sq, piece in board.piece_map().items():
        if piece.color != color or piece.piece_type == chess.KING:
            continue
        attackers = board.attackers(not color, sq)
        if not attackers:
            continue
        cheapest = min(VALUES.get(board.piece_type_at(a), 100) for a in attackers)
        if not board.attackers(color, sq) or cheapest < VALUES[piece.piece_type]:
            out.append(f"{chess.piece_name(piece.piece_type)} on {chess.square_name(sq)}")
    return sorted(out)


async def _lines(analyzer: Analyzer | None, board: chess.Board, multipv: int) -> list[Line]:
    if analyzer is None or not analyzer.available():
        return []
    try:
        return await asyncio.wait_for(analyzer.lines(board, multipv), ANALYSIS_TIMEOUT)
    except Exception:  # noqa: BLE001 - a timeout or engine trouble must not stop the answer
        return []


def _move_words(parent: chess.Board, after: chess.Board, move: chess.Move, game: Game) -> str:
    """Plain-words description of a move: from/to squares, what it captured, check, and whether the
    moved piece can be taken, so the model never has to infer any of it from SAN."""
    mover = parent.turn
    mine = mover == game.player  # the listener moved
    if parent.is_castling(move):
        words = f"castled {'kingside' if parent.is_kingside_castling(move) else 'queenside'}"
    else:
        piece = chess.piece_name(parent.piece_type_at(move.from_square))
        words = f"the {piece} moved from {chess.square_name(move.from_square)} to {chess.square_name(move.to_square)}"
        captured = (chess.Piece(chess.PAWN, not mover) if parent.is_en_passant(move)
                    else parent.piece_at(move.to_square))
        if captured:
            owner = "my" if mine else "your"
            words += f", capturing {owner} {chess.piece_name(captured.piece_type)} ({VALUES.get(captured.piece_type, 0)} points)"
        if move.promotion:
            words += f", promoting to a {chess.piece_name(move.promotion)}"
        attackers = after.attackers(not mover, move.to_square)
        if attackers and not after.is_checkmate():
            cheapest = chess.piece_name(min((after.piece_type_at(a) for a in attackers), key=lambda t: VALUES.get(t, 100)))
            defended = bool(after.attackers(mover, move.to_square))
            words += f"; the moved piece can be captured by a {cheapest} and is {'defended' if defended else 'not defended'}"
    if after.is_checkmate():
        words += ", giving checkmate"
    elif after.is_check():
        words += ", giving check"
    delta = (_material(after, game.player) - _material(after, not game.player)) - (
        _material(parent, game.player) - _material(parent, not game.player))
    if delta:
        words += f". Material change for you: {'+' if delta > 0 else '-'}{abs(delta)} points"
    return words


async def _assess_last_moves(game: Game, analyzer: Analyzer | None, plies: int = 2) -> list[str]:
    out = []
    child = game.board.copy()
    for _ in range(min(plies, len(child.move_stack))):
        move = child.pop()
        parent = child.copy()
        mover = parent.turn
        after = parent.copy()
        after.push(move)
        before_lines = await _lines(analyzer, parent, 1)
        if not before_lines:
            break
        best = before_lines[0]
        if after.is_checkmate():
            after_cp = MATE_CP
        else:
            after_lines = await _lines(analyzer, after, 1)
            if not after_lines and not after.is_game_over(claim_draw=True):
                break
            after_cp = pov_cp(after_lines[0], mover) if after_lines else 0
        before_cp = pov_cp(best, mover)
        loss = max(0, before_cp - after_cp)
        who = "you" if mover == game.player else "I"
        played = parent.san(move)
        line = f"- {who} played {played}: {_move_words(parent, after, move, game)}. Engine verdict: {move_label(loss)}"
        if move != best.first:
            listener = lambda cp: eval_words(cp if game.player == mover else -cp)  # noqa: E731
            line += (f". The engine preferred {parent.san(best.first)} "
                     f"(line: {' '.join(best.san)}), position {listener(before_cp)}; "
                     f"after the move played it is {listener(after_cp)}")
        out.append(line)
        child = parent
    return out


async def build_facts(game: Game, analyzer: Analyzer | None) -> str:
    board = game.board
    player, bot = game.player, not game.player
    opp = game.opponent
    opponent = (
        f"Maia {opp.level}, an engine that plays like a typical {opp.level}-rated human (it makes human-style mistakes)"
        if opp.type == "maia"
        else f"Stockfish limited to about {opp.level} Elo"
    )
    outcome = game.outcome()
    parts = [
        f"The listener plays {chess.COLOR_NAMES[player]} ('you'). The opponent ('I') is {opponent} and plays "
        f"{chess.COLOR_NAMES[bot]}.",
        f"It is {chess.COLOR_NAMES[board.turn]} to move, move {board.fullmove_number}."
        + (" The side to move is in check." if board.is_check() else ""),
    ]
    if outcome:
        parts.append(f"The game is over: {outcome.result()} ({outcome.termination.name.lower()}).")

    history = chess.Board().variation_san(board.move_stack) if board.move_stack else "(no moves yet)"
    if len(history) > 700:
        history = "... " + history[-700:]
    parts.append(f"Moves so far: {history}")

    read = game.board_read()["spoken"]
    parts.append(f"Your pieces: {read[chess.COLOR_NAMES[player]]}.")
    parts.append(f"My pieces: {read[chess.COLOR_NAMES[bot]]}.")
    parts.append(_captured(board, player))
    diff = _material(board, player) - _material(board, bot)
    parts.append("Material is even." if diff == 0 else
                 f"{'You are' if diff > 0 else 'I am'} up {abs(diff)} point(s) of material.")
    for color, owner in ((player, "your"), (bot, "my")):
        loose = _loose(board, color)
        if loose:
            parts.append(f"Loose or en-prise {owner} pieces: {', '.join(loose)}.")

    lines = await _lines(analyzer, board, 3)
    if lines:
        shown = [
            f"{i}. {' '.join(line.san)} -> {eval_words(pov_cp(line, player))}"
            for i, line in enumerate(lines, 1)
        ]
        parts.append("Engine's best lines for the side to move:\n" + "\n".join(shown))
    elif not outcome:
        parts.append("The engine analysis is not available right now.")

    assessments = await _assess_last_moves(game, analyzer)
    if assessments:
        parts.append("Assessment of the last moves (most recent first):\n" + "\n".join(assessments))
    return "\n".join(parts)
