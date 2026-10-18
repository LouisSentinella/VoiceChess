# Voice Chess Coach server

`python-chess` owns the game and validates every move. Engines only choose the opponent's reply. No LLM here yet (milestone 5).

## Setup

```bash
./setup-engines.sh          # Stockfish 19, lc0 (CPU, Eigen) and Maia 1100-1900 into engines/
uv sync
uv run uvicorn voicechess_server.main:app --host 127.0.0.1 --port 8765
uv run pytest
```

`engines/` is gitignored. lc0 is built with `-march=native`, so rebuild it (delete `engines/bin/lc0`, rerun the script) on a machine with a different CPU. `VOICECHESS_ENGINE_DIR` overrides the engine directory.

## API

Games live in memory, keyed by the id from `POST /game`.

| Call | Body | Returns |
| --- | --- | --- |
| `POST /game` | `{"side": "white"\|"black"\|"random", "opponent": "maia"\|"stockfish", "level": 1500}` | `{bot_move, state}`; the bot opens if you are black |
| `POST /game/{id}/move` | `{"move": "Nf3"}` (SAN or UCI) | `{player_move, bot_move, state}` |
| `GET /game/{id}/state` | | FEN, SAN moves, legal moves, check, result |
| `GET /game/{id}/board/read` | | piece squares per side, plus a `spoken` string |
| `DELETE /game/{id}` | | 204 |

- Maia `level`: 1100 to 1900 in steps of 100, run with `go nodes 1` (no search). It is deterministic: the same moves get the same replies.
- Stockfish `level`: UCI_Elo (1320 to 3190 on Stockfish 19), 0.3 s per move.
- A move that is not exactly one legal move returns 422 `{error: invalid|illegal|ambiguous, message, candidates}`. `candidates` lists the SAN options when ambiguous, so the app can ask "Nbd2 or Nfd2?".
- Threefold repetition and the fifty-move rule end the game automatically.
- If the engine fails after your move, the move is rolled back and the call returns 502.

```bash
id=$(curl -s -XPOST localhost:8765/game -H 'content-type: application/json' -d '{}' | jq -r .state.id)
curl -s -XPOST localhost:8765/game/$id/move -H 'content-type: application/json' -d '{"move":"e4"}'
```
