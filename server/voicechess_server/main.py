"""HTTP API. One in-memory game per id; python-chess referees every move."""

from __future__ import annotations

import asyncio
import random
from contextlib import asynccontextmanager
from typing import Literal

import chess
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from . import spoken
from .engines import EngineConfig, EngineError, EnginePool
from .game import Game, MoveError, OpponentSpec


class NewGame(BaseModel):
    side: Literal["white", "black", "random"] = "white"
    opponent: Literal["maia", "stockfish"] = "maia"
    # Maia: 1100-1900 in steps of 100. Stockfish: UCI_Elo.
    level: int = 1500


class MoveRequest(BaseModel):
    move: str  # SAN ("Nf3", "O-O") or UCI ("g1f3")


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
    app.state.pool = EnginePool(EngineConfig.from_env())
    app.state.games = Games()
    yield
    await app.state.pool.close()


app = FastAPI(title="Voice Chess Coach server", lifespan=lifespan)


async def _bot_move(game: Game) -> dict:
    """Have the opponent move, push it, and return its description."""
    move = await app.state.pool.choose_move(game.opponent, game.board)
    described = game.describe_move(move)
    game.board.push(move)
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


@app.post("/game/{game_id}/say")
async def say(game_id: str, req: SayRequest):
    """Resolve a speech transcript. Misses are normal outcomes, so always HTTP 200."""
    game = app.state.games.get(game_id)
    async with app.state.games.locks[game_id]:
        _check_turn(game)
        r = game.resolve_speech(req.transcript)
        if r.kind == "no_match":
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
