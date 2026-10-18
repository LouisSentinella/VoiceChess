"""Questions about the position that need no language model, so they are always right."""

from __future__ import annotations

import re

import chess

from . import spoken
from .game import Game

QUESTION_START = re.compile(
    r"^\s*(what|what's|whats|why|why's|how|how's|where|where's|wheres|which|who|when|should|shall|can|could|"
    r"would|will|is|are|am|was|were|do|does|did|have|has|tell me|explain|analy[sz]e|evaluate|give me|any|"
    r"suggest|recommend|hint|help|talk me|walk me|describe|summari[sz]e|review|assess|check my)\b",
    re.IGNORECASE,
)

NUMBER_WORDS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                "eight": 8, "nine": 9, "ten": 10}


def is_question(transcript: str) -> bool:
    """Questions start with a question word; moves never do. Checked before any move parsing."""
    return bool(QUESTION_START.match(transcript)) or transcript.strip().endswith("?")


def _owner(game: Game, color: chess.Color) -> str:
    return "your" if color == game.player else "my"


def _describe(game: Game, square: int) -> str:
    piece = game.board.piece_at(square)
    return f"{_owner(game, piece.color)} {chess.piece_name(piece.piece_type)} on {chess.square_name(square)}"


def _join(items: list[str]) -> str:
    if len(items) <= 2:
        return " and ".join(items)
    return ", ".join(items[:-1]) + " and " + items[-1]


def _squares(said: spoken.Said) -> list[int]:
    tags, found, i = said.tags, [], 0
    while i < len(tags):
        if tags[i][0] == "file" and i + 1 < len(tags) and tags[i + 1][0] == "rank":
            found.append(chess.parse_square(f"{tags[i][1]}{tags[i + 1][1]}"))
            i += 2
        else:
            i += 1
    return found


def answer(game: Game, question: str) -> str | None:
    """A one-sentence answer computed from the position, or None to ask the language model."""
    q = re.sub(r"\b(knight|bishop|rook|queen|pawn|king)s\b", r"\1", question.lower())
    q = q.replace("what's", "what is").replace("whats", "what is").replace("where's", "where is")
    said = spoken.parse(q)
    squares = _squares(said)
    board = game.board

    if squares and re.search(r"\b(attack\w*|hitting|threaten\w*)\b", q):
        sq = squares[0]
        attackers = [
            _describe(game, a)
            for color in (not game.player, game.player)
            for a in sorted(board.attackers(color, sq))
        ]
        name = chess.square_name(sq)
        if not attackers:
            return f"Nothing attacks {name}."
        return f"{_join(attackers).capitalize()} {'attacks' if len(attackers) == 1 else 'attack'} {name}."

    if squares and re.search(r"\b(defend\w*|protect\w*)\b", q):
        sq = squares[0]
        piece = board.piece_at(sq)
        name = chess.square_name(sq)
        if piece is None:
            return f"{name} is empty."
        defenders = [_describe(game, d) for d in sorted(board.attackers(piece.color, sq))]
        if not defenders:
            return f"Nothing defends {_describe(game, sq)}."
        return f"{_join(defenders).capitalize()} {'defends' if len(defenders) == 1 else 'defend'} {name}."

    if squares and re.match(r"^\s*(what|which)\b", q):
        sq = squares[0]
        if board.piece_at(sq) is None:
            return f"{chess.square_name(sq)} is empty."
        return _describe(game, sq).capitalize() + "."

    piece = next((v for k, v in said.tags if k == "piece"), None)
    if re.match(r"^\s*where\b", q) and piece is not None:
        owner_is_player = not re.search(r"\b(your|their|his|her|opponent|bot)\b", q)
        color = game.player if owner_is_player else not game.player
        squares_of = sorted(board.pieces(piece, color), key=lambda s: (chess.square_file(s), chess.square_rank(s)))
        piece_name = chess.piece_name(piece)
        owner = "your" if owner_is_player else "my"
        if not squares_of:
            return f"You have no {piece_name}s left." if owner_is_player else f"I have no {piece_name}s left."
        names = [chess.square_name(s) for s in squares_of]
        verb = "is" if len(names) == 1 else "are"
        plural = "" if len(names) == 1 else "s"
        return f"{owner.capitalize()} {piece_name}{plural} {verb} on {_join(names)}."

    if re.search(r"\blast\b.*\bmoves?\b|\b(previous|latest) move\b|what did (i|you) (just )?(play|move)", q):
        return _last_moves(game, q)

    if re.search(r"\bmaterial\b", q):
        return _material(game)
    return None


def lookup(question: str) -> tuple[int | None, int | None, str] | None:
    """If this is a "where is / what is on / attacking / defending" question, return
    (piece, square, detail) for the mistake log, else None."""
    q = re.sub(r"\b(knight|bishop|rook|queen|pawn|king)s\b", r"\1", question.lower())
    q = q.replace("what's", "what is").replace("whats", "what is").replace("where's", "where is")
    said = spoken.parse(q)
    squares = _squares(said)
    piece = next((v for k, v in said.tags if k == "piece"), None)
    square = squares[0] if squares else None
    if square is not None and re.search(r"\b(attack\w*|hitting|threaten\w*|defend\w*|protect\w*)\b", q):
        return None, square, f"attackers or defenders of {chess.square_name(square)}"
    if square is not None and re.match(r"^\s*(what|which)\b", q):
        return None, square, f"what is on {chess.square_name(square)}"
    if piece is not None and re.match(r"^\s*where\b", q):
        return piece, None, f"where is {chess.piece_name(piece)}"
    return None


def asks_about_mistakes(question: str) -> bool:
    return bool(re.search(
        r"\b(my|the) (common |usual |typical )?(mistakes?|weakness(es)?|errors?)\b|mistake log|"
        r"(keep|always) (forgetting|losing track|getting)|what do i (get wrong|forget)",
        question.lower(),
    ))


def _last_moves(game: Game, q: str) -> str:
    stack = game.board.move_stack
    if not stack:
        return "No moves have been played yet."
    plural = re.search(r"\blast\b[^.]*\bmoves\b", q) is not None
    count = 1
    m = re.search(r"\b(\d+|" + "|".join(NUMBER_WORDS) + r")\b", q)
    if m:
        count = int(m.group(1)) if m.group(1).isdigit() else NUMBER_WORDS[m.group(1)]
    elif plural:
        count = 3
    count = max(1, min(count, 10, len(stack)))

    replay = chess.Board()
    spoken_moves = []
    for move in stack:
        spoken_moves.append(spoken.speak_move(replay, move))
        replay.push(move)
    recent = [s.lower() for s in spoken_moves[-count:]]
    mover = "you" if (len(stack) % 2 == 1) == (game.player == chess.WHITE) else "I"
    if count == 1:
        return f"The last move was {recent[0]}, played by {mover}."
    return "The last moves were " + ", ".join(recent) + "."


def _material(game: Game) -> str:
    values = {chess.PAWN: 1, chess.KNIGHT: 3, chess.BISHOP: 3, chess.ROOK: 5, chess.QUEEN: 9}

    def total(color):
        return sum(len(game.board.pieces(pt, color)) * v for pt, v in values.items())

    diff = total(game.player) - total(not game.player)
    if diff == 0:
        return "Material is even."
    who, n = ("You are", diff) if diff > 0 else ("I am", -diff)
    return f"{who} up {n} point{'s' if n != 1 else ''} of material."
