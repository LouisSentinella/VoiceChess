"""Spoken forms of moves, and resolution of speech transcripts to legal moves.

The recogniser is not trusted. A transcript is parsed into what was said
(piece, origin hints, destination, promotion) and matched against the legal
moves only. It resolves to exactly one move, or the caller is told why not.
Matches that needed a recognition-error fix-up are never played silently.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Literal

import chess

PIECE_WORDS = {
    "knight": chess.KNIGHT,
    "night": chess.KNIGHT,
    "bishop": chess.BISHOP,
    "rook": chess.ROOK,
    "queen": chess.QUEEN,
    "king": chess.KING,
    "pawn": chess.PAWN,
}

FILE_WORDS = {
    **{c: c for c in "abcdefgh"},
    "alpha": "a", "alfa": "a", "ay": "a",
    "bravo": "b", "bee": "b",
    "charlie": "c", "see": "c", "sea": "c", "cee": "c",
    "delta": "d", "dee": "d",
    "echo": "e",
    "foxtrot": "f", "eff": "f", "ef": "f",
    "golf": "g", "gee": "g",
    "hotel": "h", "aitch": "h",
}

RANK_WORDS = {
    **{str(n): str(n) for n in range(1, 9)},
    "one": "1", "won": "1",
    "two": "2", "too": "2",
    "three": "3", "tree": "3", "free": "3",
    "four": "4", "for": "4", "fore": "4",
    "five": "5",
    "six": "6",
    "seven": "7",
    "eight": "8", "ate": "8",
}
RANK_SPOKEN = {"1": "one", "2": "two", "3": "three", "4": "four",
               "5": "five", "6": "six", "7": "seven", "8": "eight"}

# Letters a recogniser mixes up; used only for the fix-up pass.
CONFUSABLE_FILES = set("bcdeg")

SAN_PARTS = re.compile(r"^([NBRQK])?([a-h]?[1-8]?)(x)?([a-h][1-8])(?:=([NBRQ]))?[+#]?$")

MAX_HINTS = 100


# ---------------------------------------------------------------- speaking


def _lower_first(text: str) -> str:
    return text[:1].lower() + text[1:]


def speak_move(board: chess.Board, move: chess.Move) -> str:
    """Short announcement form of a legal move, on the board before it is played."""
    return _speak(board, move, suffix=True)


def confirm_message(board: chess.Board, move: chess.Move) -> str:
    return f"Play {_lower_first(speak_move(board, move))}?"


def _speak(board: chess.Board, move: chess.Move, suffix: bool) -> str:
    if board.is_castling(move):
        base = "Castles kingside" if board.is_kingside_castling(move) else "Castles queenside"
    else:
        san = board.san(move)
        m = SAN_PARTS.match(san)
        assert m, san  # board.san always yields this shape for non-castling moves
        letter, origin, capture, dest, promo = m.groups()
        subject = chess.piece_name(chess.PIECE_SYMBOLS.index(letter.lower())).capitalize() if letter else "Pawn"
        if origin:
            subject += f" {origin}"
        base = f"{subject} {'takes' if capture else 'to'} {dest}"
        if board.is_en_passant(move):
            base += ", en passant"
        if promo:
            base += f", promotes to {chess.piece_name(chess.PIECE_SYMBOLS.index(promo.lower()))}"
    if suffix:
        after = board.copy(stack=False)
        after.push(move)
        if after.is_checkmate():
            base += ", checkmate"
        elif after.is_check():
            base += ", check"
    return base


def spoken_result(outcome: chess.Outcome, player: chess.Color) -> str:
    t = outcome.termination
    if t == chess.Termination.CHECKMATE:
        return "Checkmate. You win." if outcome.winner == player else "Checkmate. You lose."
    return {
        chess.Termination.STALEMATE: "Draw by stalemate.",
        chess.Termination.INSUFFICIENT_MATERIAL: "Draw, insufficient material.",
        chess.Termination.THREEFOLD_REPETITION: "Draw by repetition.",
        chess.Termination.FIFTY_MOVES: "Draw by the fifty move rule.",
    }.get(t, "The game is drawn.")


def hint_phrases(board: chess.Board) -> list[str]:
    """Phrases for the recogniser's contextual strings, most useful first."""
    moves = list(board.legal_moves)
    primary: list[str] = []
    secondary: list[str] = []
    for move in moves:
        text = _speak(board, move, suffix=False).lower()
        text = re.sub(r"[1-8]", lambda m: " " + RANK_SPOKEN[m.group()], text)
        text = text.replace("castles", "castle")
        primary.append(text)
        if board.piece_type_at(move.from_square) == chess.PAWN:
            secondary.append(re.sub(r"^pawn (to )?", "", text))  # "e four", "d takes e five"
        else:
            secondary.append(re.sub(r" (to|takes) ", " ", text))  # "knight f three"
    seen: dict[str, None] = {}
    for phrase in primary + secondary:
        seen.setdefault(phrase)
    return list(seen)[:MAX_HINTS]


# ---------------------------------------------------------------- parsing


@dataclass
class Said:
    piece: int | None = None
    origin_file: str | None = None
    origin_rank: str | None = None
    dest: int | None = None  # square
    promotion: int | None = None
    castle: set[str] | None = None  # subset of {"kingside", "queenside"}
    tags: list[tuple[str, str | int]] = field(default_factory=list)


def _preprocess(text: str) -> str:
    text = text.lower().replace("’", "'")
    text = re.sub(r"\b(king|queen) ?side\b", r"\1side", text)
    text = re.sub(r"\b[o0]\s*-?\s*[o0]\s*-?\s*[o0]\b", " castle queenside ", text)
    text = re.sub(r"\b[o0]\s*-?\s*[o0]\b", " castle kingside ", text)
    return text


def parse(text: str) -> Said:
    text = _preprocess(text)
    words = re.findall(r"[a-z]+|[0-9]", text)
    said = Said()

    castle: set[str] = set()
    wants_castle = False
    tags: list[tuple[str, str | int]] = []
    for i, w in enumerate(words):
        if w in ("castle", "castles", "castling"):
            wants_castle = True
        elif w in ("kingside", "short"):
            castle.add("kingside")
        elif w in ("queenside", "long"):
            castle.add("queenside")
        elif w == "to":
            # "to" is a connector, except "e to" at the end, which is e2.
            prev_is_file = bool(tags) and tags[-1][0] == "file"
            if prev_is_file and i == len(words) - 1:
                tags.append(("rank", "2"))
        elif w in PIECE_WORDS:
            tags.append(("piece", PIECE_WORDS[w]))
        elif w in RANK_WORDS:
            tags.append(("rank", RANK_WORDS[w]))
        elif w in FILE_WORDS:
            tags.append(("file", FILE_WORDS[w]))
        # anything else ("takes", "play", "my", noise) is ignored
    said.tags = tags

    if wants_castle or castle:
        said.castle = castle or {"kingside", "queenside"}
        return said

    # Destination: the last file followed directly by a rank.
    dest_at = next(
        (i for i in range(len(tags) - 2, -1, -1)
         if tags[i][0] == "file" and tags[i + 1][0] == "rank"),
        None,
    )
    if dest_at is None:
        return said
    said.dest = chess.parse_square(f"{tags[dest_at][1]}{tags[dest_at + 1][1]}")

    for kind, value in tags[dest_at + 2:]:
        if kind == "piece" and value != chess.PAWN:
            said.promotion = value  # type: ignore[assignment]
            break

    before = tags[:dest_at]
    said.piece = next((v for k, v in before if k == "piece"), None)  # type: ignore[assignment]
    rest = [(k, v) for k, v in before if k != "piece"]
    j = 0
    while j < len(rest):
        k, v = rest[j]
        if k == "file" and j + 1 < len(rest) and rest[j + 1][0] == "rank":
            said.origin_file, said.origin_rank = v, rest[j + 1][1]  # type: ignore[assignment]
            j += 2
            continue
        if k == "file":
            said.origin_file = v  # type: ignore[assignment]
        else:
            said.origin_rank = v  # type: ignore[assignment]
        j += 1
    return said


# -------------------------------------------------------------- resolution


@dataclass
class Resolution:
    kind: Literal["move", "confirm", "ambiguous", "no_match"]
    move: chess.Move | None = None
    candidates: list[chess.Move] = field(default_factory=list)
    message: str = ""


NO_MATCH = Resolution("no_match", message="I did not catch a legal move.")


def _file_ok(said: str, actual: str, relaxed: bool) -> bool:
    return said == actual or (relaxed and said in CONFUSABLE_FILES and actual in CONFUSABLE_FILES)


def _matches(board: chess.Board, move: chess.Move, said: Said, relaxed: bool) -> bool:
    if said.dest is None:
        return False
    want, got = chess.square_name(said.dest), chess.square_name(move.to_square)
    if want[1] != got[1] or not _file_ok(want[0], got[0], relaxed):
        return False
    if said.piece is not None and board.piece_type_at(move.from_square) != said.piece:
        return False
    src = chess.square_name(move.from_square)
    if said.origin_file and not _file_ok(said.origin_file, src[0], relaxed):
        return False
    if said.origin_rank and said.origin_rank != src[1]:
        return False
    if said.promotion and move.promotion != said.promotion:
        return False
    return True


def _filter(board: chess.Board, said: Said, relaxed: bool) -> list[chess.Move]:
    moves = sorted(board.legal_moves, key=lambda m: (m.from_square, m.to_square, -(m.promotion or 0)))
    if said.castle is not None:
        return [
            m for m in moves
            if board.is_castling(m)
            and ("kingside" if board.is_kingside_castling(m) else "queenside") in said.castle
        ]
    found = [m for m in moves if _matches(board, m, said, relaxed)]
    if said.piece is None:
        pawns = [m for m in found if board.piece_type_at(m.from_square) == chess.PAWN]
        if pawns:
            return pawns
    return found


def _try_san_token(board: chess.Board, text: str) -> chess.Move | None:
    """One-token transcripts such as 'Nf3', 'exd5', 'Nbd2'."""
    token = text.strip()
    if " " in token or not 2 <= len(token) <= 7:
        return None
    for candidate in (token, token[0].upper() + token[1:] if token[0] in "nrqk" else token):
        try:
            return board.parse_san(candidate)
        except ValueError:  # invalid, illegal and ambiguous SAN all derive from it
            continue
    return None


def _from_pending(board: chess.Board, said: Said, pending: list[chess.Move]) -> chess.Move | None:
    """Short answers to a disambiguation question: 'f three', 'the b knight', 'queen'."""
    squares: set[int] = set()
    files: list[str] = []
    ranks: list[str] = []
    tags = said.tags
    i = 0
    while i < len(tags):
        kind, value = tags[i]
        if kind == "file" and i + 1 < len(tags) and tags[i + 1][0] == "rank":
            squares.add(chess.parse_square(f"{value}{tags[i + 1][1]}"))
            i += 2
            continue
        if kind == "file":
            files.append(value)  # type: ignore[arg-type]
        elif kind == "rank":
            ranks.append(value)  # type: ignore[arg-type]
        i += 1
    pieces = {v for k, v in tags if k == "piece"}
    if not (squares or files or ranks or pieces):
        return None

    def ok(m: chess.Move) -> bool:
        src = chess.square_name(m.from_square)
        if squares and m.from_square not in squares:
            return False
        if files and src[0] not in files:
            return False
        if ranks and src[1] not in ranks:
            return False
        if pieces:
            kind = m.promotion or board.piece_type_at(m.from_square)
            if kind not in pieces:
                return False
        return True

    left = [m for m in pending if ok(m)]
    return left[0] if len(left) == 1 else None


def _ask(board: chess.Board, moves: list[chess.Move]) -> str:
    same_squares = len({(m.from_square, m.to_square) for m in moves}) == 1
    if same_squares and all(m.promotion for m in moves):
        names = [chess.piece_name(m.promotion) for m in moves]
        return "Promote to " + _or_join(names) + "?"
    return "Did you mean " + _or_join([_lower_first(speak_move(board, m)) for m in moves]) + "?"


def _or_join(items: list[str]) -> str:
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + " or " + items[-1]


def resolve(board: chess.Board, transcript: str, pending: list[chess.Move]) -> Resolution:
    """Turn a transcript into one legal move, a clarification, or a miss."""
    said = parse(transcript)

    if pending:
        move = _from_pending(board, said, [m for m in pending if m in board.legal_moves])
        if move:
            return Resolution("move", move)

    san_move = _try_san_token(board, transcript)
    if san_move:
        return Resolution("move", san_move)

    exact = _filter(board, said, relaxed=False)
    if len(exact) == 1:
        # A non-pawn reading of an unprefixed square ("f three") is a guess.
        guessed = said.piece is None and said.castle is None and \
            board.piece_type_at(exact[0].from_square) != chess.PAWN
        if guessed:
            return Resolution("confirm", exact[0], message=confirm_message(board, exact[0]))
        return Resolution("move", exact[0])
    if len(exact) > 1:
        return Resolution("ambiguous", candidates=exact, message=_ask(board, exact))

    if said.castle is None:
        fuzzy = _filter(board, said, relaxed=True)
        if len(fuzzy) == 1:
            return Resolution("confirm", fuzzy[0], message=confirm_message(board, fuzzy[0]))
        if len(fuzzy) > 1:
            return Resolution("ambiguous", candidates=fuzzy, message=_ask(board, fuzzy))
    return NO_MATCH


# ------------------------------------------------- moves inside free text

_SAN_IN_TEXT = re.compile(
    r"\b(?P<castle>O-O-O|0-0-0|O-O|0-0)(?P<ccheck>[+#])?(?!\w)"
    r"|\b(?P<piece>[NBRQK])(?P<origin>[a-h]?[1-8]?)(?P<cap>x)?(?P<dest>[a-h][1-8])(?:=(?P<promo>[NBRQ]))?(?P<check>[+#])?(?!\w)"
    r"|\b(?P<pfile>[a-h])x(?P<pdest>[a-h][1-8])(?:=(?P<ppromo>[NBRQ]))?(?P<pcheck>[+#])?(?!\w)"
)
_LETTER_NAME = {"N": "knight", "B": "bishop", "R": "rook", "Q": "queen", "K": "king"}


def _check_word(mark: str | None) -> str:
    return {"+": ", check", "#": ", checkmate"}.get(mark or "", "")


def san_to_speech(text: str) -> str:
    """Rewrite SAN move tokens in free text the way speak_move announces them."""

    def repl(m: re.Match) -> str:
        if m.group("castle"):
            side = "queenside" if m.group("castle").count("-") == 2 else "kingside"
            return f"castles {side}{_check_word(m.group('ccheck'))}"
        if m.group("piece"):
            origin = f" {m.group('origin')}" if m.group("origin") else ""
            promo = f", promotes to {_LETTER_NAME[m.group('promo')]}" if m.group("promo") else ""
            verb = "takes" if m.group("cap") else "to"
            return (f"{_LETTER_NAME[m.group('piece')]}{origin} {verb} {m.group('dest')}"
                    f"{promo}{_check_word(m.group('check'))}")
        promo = f", promotes to {_LETTER_NAME[m.group('ppromo')]}" if m.group("ppromo") else ""
        return f"pawn {m.group('pfile')} takes {m.group('pdest')}{promo}{_check_word(m.group('pcheck'))}"

    return _SAN_IN_TEXT.sub(repl, text)
