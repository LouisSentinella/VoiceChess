"""Game state. python-chess owns the position; nothing here talks to an engine."""

from __future__ import annotations

import re
import secrets
from dataclasses import dataclass, field
from typing import Literal

import chess

from . import spoken

UCI_RE = re.compile(r"^[a-h][1-8][a-h][1-8][qrbn]?$")
SQUARE_RE = re.compile(r"[a-h][1-8]")

PIECE_ORDER = [
    chess.KING,
    chess.QUEEN,
    chess.ROOK,
    chess.BISHOP,
    chess.KNIGHT,
    chess.PAWN,
]
PIECE_LETTER = {
    "N": chess.KNIGHT,
    "B": chess.BISHOP,
    "R": chess.ROOK,
    "Q": chess.QUEEN,
    "K": chess.KING,
}


class MoveError(Exception):
    """Raised when text cannot be turned into exactly one legal move."""

    def __init__(
        self,
        kind: Literal["invalid", "illegal", "ambiguous"],
        message: str,
        candidates: list[str] | None = None,
    ):
        super().__init__(message)
        self.kind = kind
        self.message = message
        self.candidates = candidates or []


@dataclass
class OpponentSpec:
    type: Literal["maia", "stockfish"]
    level: int  # Maia rating (1100-1900) or Stockfish UCI_Elo


@dataclass
class Game:
    id: str
    player: chess.Color
    opponent: OpponentSpec
    board: chess.Board = field(default_factory=chess.Board)
    # Moves offered by the last "did you mean" question; the next transcript is
    # matched against these first.
    pending: list[chess.Move] = field(default_factory=list)
    # Recent (question, answer) pairs for the coach, so follow-ups make sense.
    chat: list[tuple[str, str]] = field(default_factory=list)

    @staticmethod
    def new_id() -> str:
        return secrets.token_urlsafe(6)

    @property
    def player_name(self) -> str:
        return chess.COLOR_NAMES[self.player]

    def is_over(self) -> bool:
        return self.outcome() is not None

    def outcome(self) -> chess.Outcome | None:
        # claim_draw: threefold repetition and the fifty-move rule end the game
        # automatically, since a voice player has no "claim draw" button.
        return self.board.outcome(claim_draw=True)

    def resolve_move(self, text: str) -> chess.Move:
        """Resolve SAN or UCI text to a legal move on the current board."""
        text = text.strip()
        if not text:
            raise MoveError("invalid", "Empty move.")

        if UCI_RE.match(text.lower()):
            try:
                move = chess.Move.from_uci(text.lower())
            except chess.InvalidMoveError:  # e.g. "a1a1"
                raise MoveError("invalid", f"{text} is not a move.") from None
            if move in self.board.legal_moves:
                return move
            # A pawn reaching the last rank without a promotion piece.
            queen = chess.Move(move.from_square, move.to_square, chess.QUEEN)
            if queen in self.board.legal_moves:
                raise MoveError(
                    "ambiguous",
                    f"{text} is a promotion; say which piece.",
                    [self.board.san(chess.Move(move.from_square, move.to_square, p))
                     for p in (chess.QUEEN, chess.ROOK, chess.BISHOP, chess.KNIGHT)],
                )
            raise MoveError("illegal", f"{text} is not a legal move.")

        try:
            return self.board.parse_san(text)
        except chess.AmbiguousMoveError:
            raise MoveError(
                "ambiguous",
                f"{text} could be more than one move.",
                self._candidates(text),
            ) from None
        except chess.IllegalMoveError:
            raise MoveError("illegal", f"{text} is not legal here.") from None
        except chess.InvalidMoveError:
            raise MoveError("invalid", f"{text} is not a move.") from None

    def _candidates(self, text: str) -> list[str]:
        squares = SQUARE_RE.findall(text.lower())
        if not squares:
            return []
        dest = chess.parse_square(squares[-1])
        piece = PIECE_LETTER.get(text[0], chess.PAWN)
        return [
            self.board.san(m)
            for m in self.board.legal_moves
            if m.to_square == dest
            and self.board.piece_type_at(m.from_square) == piece
        ]

    def play(self, move: chess.Move) -> None:
        self.board.push(move)
        self.pending = []

    def resolve_speech(self, transcript: str) -> spoken.Resolution:
        resolution = spoken.resolve(self.board, transcript, self.pending)
        self.pending = resolution.candidates if resolution.kind == "ambiguous" else []
        return resolution

    def hints(self) -> list[str]:
        return spoken.hint_phrases(self.board)

    def describe_move(self, move: chess.Move) -> dict:
        """Describe a legal move on the current board, before it is pushed."""
        board = self.board
        piece = board.piece_type_at(move.from_square)
        after = board.copy(stack=False)
        after.push(move)
        return {
            "san": board.san(move),
            "uci": move.uci(),
            "piece": chess.piece_name(piece),
            "from": chess.square_name(move.from_square),
            "to": chess.square_name(move.to_square),
            "capture": board.is_capture(move),
            "castle": "kingside" if board.is_kingside_castling(move)
            else "queenside" if board.is_queenside_castling(move) else None,
            "promotion": chess.piece_name(move.promotion) if move.promotion else None,
            "check": after.is_check(),
            "checkmate": after.is_checkmate(),
            "spoken": spoken.speak_move(board, move),
        }

    def move_list(self) -> list[str]:
        replay = chess.Board()
        out = []
        for move in self.board.move_stack:
            out.append(replay.san(move))
            replay.push(move)
        return out

    def state(self) -> dict:
        board = self.board
        outcome = self.outcome()
        moves = self.move_list()
        last = board.peek() if board.move_stack else None
        return {
            "id": self.id,
            "player": self.player_name,
            "opponent": {"type": self.opponent.type, "level": self.opponent.level},
            "fen": board.fen(),
            "turn": chess.COLOR_NAMES[board.turn],
            "your_turn": board.turn == self.player,
            "moves": moves,
            "last_move": moves[-1] if moves else None,
            "last_move_uci": last.uci() if last else None,
            "legal_moves": sorted(board.san(m) for m in board.legal_moves),
            "legal_moves_uci": sorted(m.uci() for m in board.legal_moves),
            "in_check": board.is_check(),
            "game_over": outcome is not None,
            "result": outcome.result() if outcome else None,
            "termination": outcome.termination.name.lower() if outcome else None,
            "spoken_result": spoken.spoken_result(outcome, self.player) if outcome else None,
        }

    def board_read(self) -> dict:
        """Piece locations computed from the position, grouped by side."""
        board = self.board
        pieces: dict[str, dict[str, list[str]]] = {}
        for color in (chess.WHITE, chess.BLACK):
            side: dict[str, list[str]] = {}
            for ptype in PIECE_ORDER:
                squares = sorted(
                    board.pieces(ptype, color),
                    key=lambda s: (chess.square_file(s), chess.square_rank(s)),
                )
                if squares:
                    side[chess.piece_name(ptype)] = [chess.square_name(s) for s in squares]
            pieces[chess.COLOR_NAMES[color]] = side
        return {
            "player": self.player_name,
            "pieces": pieces,
            "spoken": {name: _spoken(side) for name, side in pieces.items()},
        }


def _spoken(side: dict[str, list[str]]) -> str:
    parts = []
    for name, squares in side.items():
        label = name if len(squares) == 1 else name + "s"
        parts.append(f"{label} {_join(squares)}")
    return ", ".join(parts)


def _join(items: list[str]) -> str:
    if len(items) <= 2:
        return " and ".join(items)
    return ", ".join(items[:-1]) + " and " + items[-1]
