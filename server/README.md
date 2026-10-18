# Voice Chess Coach server

`python-chess` owns the game and validates every move. Engines only choose the opponent's reply. No LLM here yet (milestone 5).

## Setup

```bash
./setup-engines.sh          # Stockfish 19, lc0 (CPU, Eigen), Maia 1100-1900 and Kokoro TTS into engines/
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
| `GET /game/{id}/hints` | | spoken forms of every legal move, for the recogniser |
| `POST /game/{id}/say` | `{"transcript": "knight to f three", "confirm": false}` | played, confirm, ambiguous or no_match; see `docs/api.md` |
| `POST /tts` | `{"text": "Knight to f3", "voice": "af_heart", "speed": 1.0}` | 24 kHz mono WAV (Kokoro, about 0.4 s per phrase on CPU, cached); 503 if the model is missing |
| `GET /tts/voices` | | `{voices, default}`; default voice from `VOICECHESS_TTS_VOICE` |
| `POST /game/{id}/ask` | `{"question": "why was that a mistake"}` | NDJSON stream of spoken sentences, see `docs/api.md` |
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

## Coach (questions)

`/say` returns `{"status": "question"}` for transcripts that start with a question word, before any move parsing ("what is on e4" never plays e4). The app then calls `/ask`:

- Board questions (what is on / attacking / defending a square, where is my knight, last moves, material) are answered from the position directly, with no model.
- Everything else goes to a language model. It is given only facts computed here: FEN-derived piece lists, loose pieces, material, Stockfish's top 3 lines, and an engine assessment of the last two moves (loss in pawns, better move). The model only talks; it never decides a move.
- Answers stream sentence by sentence. SAN in the text is rewritten to spoken form.

Language model backends are OpenAI-compatible and tried in order until one streams:

| Setting | Meaning |
| --- | --- |
| `VOICECHESS_LLM` | ordered list of `openrouter` and `local`; default `openrouter,local` if a key exists, else `local` |
| `OPENROUTER_API_KEY` | hosted backend key |
| `VOICECHESS_LLM_MODEL` | hosted model, default `anthropic/claude-haiku-5.5` |
| `VOICECHESS_LOCAL_LLM_URL` | local llama.cpp or Ollama server, default `http://127.0.0.1:8081/v1` |

Put keys in `~/.config/voicechess/env` (read by the systemd unit), never in git. The local model runs with `systemctl --user start voicechess-llm` (not enabled at boot: it holds about 4 GB of VRAM while running).
