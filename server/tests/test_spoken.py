import chess
import pytest

from voicechess_server import spoken
from voicechess_server.game import Game, OpponentSpec

KNIGHTS_TO_D2 = "rnbqkbnr/pppppppp/8/8/8/5N2/PPP1PPPP/RNBQKB1R w KQkq - 0 1"


def board(fen: str = chess.STARTING_FEN, moves: str = "") -> chess.Board:
    b = chess.Board(fen)
    for m in moves.split():
        b.push_san(m)
    return b


def said(b: chess.Board, text: str, pending=None) -> spoken.Resolution:
    return spoken.resolve(b, text, pending or [])


@pytest.mark.parametrize(
    "text",
    [
        "knight to f three",
        "Knight f3",
        "knight to foxtrot three",
        "Nf3",
        "play knight to f 3",
        "knight to eff tree",
    ],
)
def test_knight_move_phrasings(text):
    r = said(board(), text)
    assert r.kind == "move" and r.move == chess.Move.from_uci("g1f3")


@pytest.mark.parametrize("text", ["e four", "pawn to echo four", "e for", "E4", "e2 to e4", "e two e four"])
def test_pawn_move_phrasings(text):
    r = said(board(), text)
    assert r.kind == "move" and r.move == chess.Move.from_uci("e2e4")


def test_to_between_squares_is_a_connector():
    # "e to e four" and "e two e four" both mean e2-e4; neither may break parsing.
    assert said(board(), "e to e four").move == chess.Move.from_uci("e2e4")


def test_castling_words_and_symbols():
    b = board(moves="e4 e5 Nf3 Nc6 Bc4 Bc5")
    for text in ("castle kingside", "castles short", "o-o", "castle king side"):
        r = said(b, text)
        assert r.kind == "move" and r.move == chess.Move.from_uci("e1g1"), text


def test_castle_without_a_side_is_ambiguous_when_both_are_legal():
    b = chess.Board("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
    r = said(b, "castle")
    assert r.kind == "ambiguous" and len(r.candidates) == 2
    assert "kingside" in r.message and "queenside" in r.message


def test_pawn_capture_by_file_and_by_bare_piece():
    b = board(moves="e4 d5")
    assert said(b, "e takes d five").move == chess.Move.from_uci("e4d5")
    assert said(b, "pawn takes d5").move == chess.Move.from_uci("e4d5")


def test_two_knights_ask_which_and_short_answers_resolve():
    b = board(KNIGHTS_TO_D2)
    r = said(b, "knight to d two")
    assert r.kind == "ambiguous"
    assert r.message == "Did you mean knight b to d2 or knight f to d2?"
    # Answer by origin square, or by origin file.
    assert said(b, "f three", r.candidates).move == chess.Move.from_uci("f3d2")
    assert said(b, "the b knight", r.candidates).move == chess.Move.from_uci("b1d2")


def test_promotion_asks_for_the_piece_unless_said():
    b = chess.Board("8/4P3/8/8/8/8/k7/4K3 w - - 0 1")
    r = said(b, "e eight")
    assert r.kind == "ambiguous" and r.message == "Promote to queen, rook, bishop or knight?"
    assert said(b, "e eight queen").move == chess.Move.from_uci("e7e8q")
    assert said(b, "queen", r.candidates).move == chess.Move.from_uci("e7e8q")


def test_misheard_file_letter_needs_confirmation_never_plays_silently():
    # "d four" is not legal, but c4 is the only bishop move one letter-confusion away.
    b = board(moves="e4 e5")
    r = said(b, "bishop to d four")
    assert r.kind == "confirm" and r.move == chess.Move.from_uci("f1c4")
    assert r.message == "Play bishop to c4?"


def test_bare_square_that_only_a_piece_can_reach_needs_confirmation():
    b = chess.Board("4k3/8/8/8/8/8/8/4K1N1 w - - 0 1")
    r = said(b, "f three")
    assert r.kind == "confirm" and r.move == chess.Move.from_uci("g1f3")


@pytest.mark.parametrize("text", ["", "banana", "knight to e five", "hello there"])
def test_nonsense_and_illegal_moves_do_not_match(text):
    assert said(board(), text).kind == "no_match"


def test_pending_candidates_do_not_swallow_an_unrelated_move():
    b = board(KNIGHTS_TO_D2)
    r = said(b, "knight to d two")
    assert said(b, "e four", r.candidates).move == chess.Move.from_uci("e2e4")


def test_announcement_forms():
    assert spoken.speak_move(board(), chess.Move.from_uci("g1f3")) == "Knight to f3"
    assert spoken.speak_move(board(), chess.Move.from_uci("e2e4")) == "Pawn to e4"
    assert spoken.speak_move(board(moves="e4 d5"), chess.Move.from_uci("e4d5")) == "Pawn e takes d5"
    assert spoken.speak_move(board(KNIGHTS_TO_D2), chess.Move.from_uci("b1d2")) == "Knight b to d2"
    castle = board(moves="e4 e5 Nf3 Nc6 Bc4 Bc5")
    assert spoken.speak_move(castle, chess.Move.from_uci("e1g1")) == "Castles kingside"
    assert spoken.speak_move(chess.Board("k7/4P3/8/8/8/8/8/4K3 w - - 0 1"),
                             chess.Move.from_uci("e7e8q")) == "Pawn to e8, promotes to queen, check"
    ep = board(moves="e4 a6 e5 d5")
    assert spoken.speak_move(ep, chess.Move.from_uci("e5d6")) == "Pawn e takes d6, en passant"


def test_spoken_result_names_the_winner_from_the_players_side():
    mate = chess.Board("rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3")
    outcome = mate.outcome()
    assert spoken.spoken_result(outcome, chess.WHITE) == "Checkmate. You lose."
    assert spoken.spoken_result(outcome, chess.BLACK) == "Checkmate. You win."


def test_hints_are_capped_deduplicated_and_spoken_digit_free():
    phrases = Game("t", chess.WHITE, OpponentSpec("maia", 1500)).hints()
    assert 0 < len(phrases) <= spoken.MAX_HINTS
    assert len(set(phrases)) == len(phrases)
    assert "knight to f three" in phrases and "e four" in phrases
    assert not any(ch.isdigit() for p in phrases for ch in p)
