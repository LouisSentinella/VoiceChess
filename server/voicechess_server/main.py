"""HTTP API. One in-memory game per id; python-chess referees every move."""

from __future__ import annotations

import asyncio
import json
import os
import random
from contextlib import asynccontextmanager
from typing import Literal

import chess
from fastapi import FastAPI, HTTPException, Response
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from . import coach, qa, review, spoken
from .analysis import Analyzer
from .engines import EngineConfig, EngineError, EnginePool
from .game import Game, MoveError, OpponentSpec
from .llm import LlmClient, backends_from_env
from .mistakes import MistakeLog
from .tts import MAX_TEXT, Tts, TtsError


class NewGame(BaseModel):
    side: Literal["white", "black", "random"] = "white"
    opponent: Literal["maia", "stockfish"] = "maia"
    # Maia: 1100-1900 in steps of 100. Stockfish: UCI_Elo.
    level: int = 1500


class MoveRequest(BaseModel):
    move: str  # SAN ("Nf3", "O-O") or UCI ("g1f3")


class AskRequest(BaseModel):
    question: str


class TtsRequest(BaseModel):
    text: str
    voice: str | None = None
    speed: float = 1.0


class SayRequest(BaseModel):
    transcript: str
    confirm: bool = False  # resolve but do not play; ask the player first


class Games:
    """Game registry. The lock stops two requests moving the same game at once."""

    def __init__(self) -> None:
        self.games: dict[str, Game] = {}
        self.locks: dict[str, asyncio.Lock] = {}

    def add(self, game: Game) -> None:
        self.games[game.id] = game
        self.locks[game.id] = asyncio.Lock()

    def get(self, game_id: str) -> Game:
        try:
            return self.games[game_id]
        except KeyError:
            raise HTTPException(404, f"No game {game_id}.") from None

    def remove(self, game_id: str) -> None:
        self.get(game_id)
        del self.games[game_id]
        del self.locks[game_id]


@asynccontextmanager
async def lifespan(app: FastAPI):
    config = EngineConfig.from_env()
    app.state.pool = EnginePool(config)
    app.state.games = Games()
    app.state.tts = Tts(
        config.tts_model, config.tts_voices, os.environ.get("VOICECHESS_TTS_VOICE", "af_heart")
    )
    app.state.analyzer = Analyzer(config.stockfish)
    app.state.llm = LlmClient(backends_from_env())
    app.state.background = set()
    app.state.log = MistakeLog()
    warm = asyncio.create_task(app.state.tts.warm())  # first phrase should not pay the model load
    yield
    warm.cancel()
    for task in list(app.state.background):
        task.cancel()
    await app.state.pool.close()
    await app.state.analyzer.close()
    await app.state.llm.close()
    app.state.log.close()


app = FastAPI(title="Voice Chess Coach server", lifespan=lifespan)


def _warm(game: Game) -> None:
    """Analyse the current position in the background so a later question finds it cached."""
    analyzer: Analyzer = app.state.analyzer
    if not analyzer.available():
        return
    board = game.board.copy(stack=False)

    async def run() -> None:
        try:
            await analyzer.lines(board, 3)
        except Exception:  # noqa: BLE001 - best-effort cache fill
            pass

    task = asyncio.create_task(run())
    app.state.background.add(task)
    task.add_done_callback(app.state.background.discard)


async def _bot_move(game: Game) -> dict:
    """Have the opponent move, push it, and return its description."""
    move = await app.state.pool.choose_move(game.opponent, game.board)
    described = game.describe_move(move)
    game.board.push(move)
    _warm(game)
    return described


@app.post("/game", status_code=201)
async def new_game(req: NewGame):
    spec = OpponentSpec(req.opponent, req.level)
    try:
        await app.state.pool.prepare(spec)
    except EngineError as e:
        raise HTTPException(422, str(e)) from None

    color = {"white": chess.WHITE, "black": chess.BLACK}.get(req.side)
    if color is None:
        color = random.choice([chess.WHITE, chess.BLACK])
    game = Game(Game.new_id(), color, spec)
    app.state.games.add(game)

    bot_move = None
    if game.board.turn != game.player:
        try:
            bot_move = await _bot_move(game)
        except EngineError as e:
            app.state.games.remove(game.id)
            raise HTTPException(502, str(e)) from None
    return {"bot_move": bot_move, "state": game.state()}


def _check_turn(game: Game) -> None:
    if game.is_over():
        raise HTTPException(409, "The game is over.")
    if game.board.turn != game.player:
        raise HTTPException(409, "It is not your turn.")


async def _play(game: Game, move: chess.Move) -> dict:
    """Play the player's move, then the bot's reply. Caller holds the game lock."""
    player_move = game.describe_move(move)
    game.play(move)
    _warm(game)  # analyse the position the bot is about to move from, in the background

    bot_move = None
    if not game.is_over():
        try:
            bot_move = await _bot_move(game)
        except EngineError as e:
            game.board.pop()  # the player's move stands only if the reply happened
            raise HTTPException(502, str(e)) from None
    return {"player_move": player_move, "bot_move": bot_move, "state": game.state()}


@app.post("/game/{game_id}/move")
async def play_move(game_id: str, req: MoveRequest):
    game = app.state.games.get(game_id)
    async with app.state.games.locks[game_id]:
        _check_turn(game)
        try:
            move = game.resolve_move(req.move)
        except MoveError as e:
            raise HTTPException(
                422, {"error": e.kind, "message": e.message, "candidates": e.candidates}
            ) from None
        return await _play(game, move)


def _candidate(game: Game, move: chess.Move) -> dict:
    return {"san": game.board.san(move), "spoken": spoken.speak_move(game.board, move)}


def _log_illegal_attempt(game: Game, transcript: str) -> None:
    """A transcript that names a piece and a square but matches no legal move is a lost-track signal."""
    said = spoken.parse(transcript)
    if said.piece is not None and said.dest is not None and said.castle is None:
        app.state.log.record(
            "illegal_attempt", game.id, len(game.board.move_stack),
            transcript.strip(), said.piece, said.dest,
        )


@app.post("/game/{game_id}/say")
async def say(game_id: str, req: SayRequest):
    """Resolve a speech transcript. Misses are normal outcomes, so always HTTP 200."""
    game = app.state.games.get(game_id)
    if qa.is_question(req.transcript):  # before move parsing: "what is on e4" must never play e4
        return {"status": "question", "question": req.transcript.strip()}
    async with app.state.games.locks[game_id]:
        _check_turn(game)
        r = game.resolve_speech(req.transcript)
        if r.kind == "no_match":
            _log_illegal_attempt(game, req.transcript)
            return {"status": "no_match", "message": r.message}
        if r.kind == "ambiguous":
            return {
                "status": "ambiguous",
                "message": r.message,
                "candidates": [_candidate(game, m) for m in r.candidates],
            }
        if r.kind == "confirm" or req.confirm:
            return {
                "status": "confirm",
                "candidate": _candidate(game, r.move),
                "message": spoken.confirm_message(game.board, r.move),
            }
        return {"status": "played", **await _play(game, r.move)}


@app.post("/game/{game_id}/ask")
async def ask(game_id: str, req: AskRequest):
    """Answer a question about the game as an NDJSON stream of spoken sentences."""
    game = app.state.games.get(game_id)
    question = req.question.strip()
    if not question:
        raise HTTPException(422, "Empty question.")

    async def events():
        # Held for the whole answer: the position must not change under the model.
        async with app.state.games.locks[game_id]:
            async for event in coach.answer(
                game, question, app.state.analyzer, app.state.llm, app.state.log
            ):
                yield json.dumps(event) + "\n"

    return StreamingResponse(events(), media_type="application/x-ndjson")


@app.get("/game/{game_id}/hints")
async def get_hints(game_id: str):
    return {"phrases": app.state.games.get(game_id).hints()}


@app.get("/game/{game_id}/state")
async def get_state(game_id: str):
    return app.state.games.get(game_id).state()


@app.get("/game/{game_id}/board/read")
async def read_board(game_id: str):
    return app.state.games.get(game_id).board_read()


@app.delete("/game/{game_id}", status_code=204)
async def end_game(game_id: str):
    app.state.games.remove(game_id)


@app.get("/tts/voices")
async def tts_voices():
    tts: Tts = app.state.tts
    try:
        return {"voices": await tts.voices(), "default": tts.default_voice}
    except TtsError as e:
        raise HTTPException(503, str(e)) from None


@app.post("/tts")
async def tts_speak(req: TtsRequest):
    """Synthesise a short phrase to 24 kHz mono WAV."""
    text = req.text.strip()
    if not text or len(text) > MAX_TEXT:
        raise HTTPException(422, f"Text must be 1-{MAX_TEXT} characters.")
    if not 0.5 <= req.speed <= 2.0:
        raise HTTPException(422, "Speed must be between 0.5 and 2.0.")
    try:
        wav = await app.state.tts.synthesize(text, req.voice, req.speed)
    except TtsError as e:
        raise HTTPException(503, str(e)) from None
    except ValueError as e:
        raise HTTPException(422, str(e)) from None
    return Response(wav, media_type="audio/wav")


@app.get("/game/{game_id}/review")
async def game_review(game_id: str):
    game = app.state.games.get(game_id)
    async with app.state.games.locks[game_id]:
        return await review.review(game, app.state.analyzer)


@app.post("/game/{game_id}/review/{ply}/explain")
async def explain_moment(game_id: str, ply: int):
    """Stream a spoken explanation of one of the listener's moves, as the game stood after it."""
    game = app.state.games.get(game_id)
    if ply not in review.listener_plies(game):
        raise HTTPException(404, f"Ply {ply} is not one of your moves.")
    moment = review.moment_game(game, ply)
    before = moment.board.copy()
    move = before.pop()
    question = (
        f"Explain why my move {spoken.speak_move(before, move).lower()} was a mistake "
        "and what I should have played instead."
    )

    async def events():
        async for event in coach.answer(moment, question, app.state.analyzer, app.state.llm):
            yield json.dumps(event) + "\n"

    return StreamingResponse(events(), media_type="application/x-ndjson")


@app.get("/log/summary")
async def log_summary():
    return app.state.log.summary()
