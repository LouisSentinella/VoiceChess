# API contract (server <-> iOS app)

Base URL default: `https://louis-desktop.tail4f111a.ts.net` (tailnet only). JSON everywhere. Errors that are not voice outcomes use HTTP status codes with `{"detail": ...}`: 404 unknown game, 409 game over or not your turn, 422 bad request, 502 engine failure.

## Types

`MoveInfo`
```json
{"san":"Nf3","uci":"g1f3","piece":"knight","from":"g1","to":"f3","capture":false,
 "castle":null,"promotion":null,"check":false,"checkmate":false,
 "spoken":"Knight to f3"}
```
`castle` is `"kingside"`, `"queenside"` or null. `promotion` is a piece name or null. `spoken` is the short announcement form the app speaks verbatim, e.g. `Pawn e takes d5`, `Knight b to d2` (disambiguated), `Castles kingside`, `Queen takes d7, check`, `Pawn to e8, promotes to queen, checkmate`.

`State`
```json
{"id":"5pP1UBl9","player":"white","opponent":{"type":"maia","level":1500},
 "fen":"...","turn":"white","your_turn":true,"moves":["e4","e5"],
 "last_move":"e5","last_move_uci":"e7e5","legal_moves":["Nf3"],"legal_moves_uci":["g1f3"],
 "in_check":false,"game_over":false,"result":null,"termination":null,
 "spoken_result":null}
```
`result` is `"1-0"`, `"0-1"`, `"1/2-1/2"` or null. `spoken_result` is null while the game runs, else a sentence to speak, e.g. `Checkmate. You win.`, `Draw by stalemate.`.

## Endpoints

| Call | Body | Response |
| --- | --- | --- |
| `POST /game` | `{"side":"white"\|"black"\|"random","opponent":"maia"\|"stockfish","level":1500}` (all optional) | 201 `{"bot_move": MoveInfo\|null, "state": State}`. The bot has already opened if you are black. |
| `POST /game/{id}/say` | `{"transcript":"knight to f three","confirm":false}` | one of the three voice outcomes below, always HTTP 200 |
| `POST /game/{id}/move` | `{"move":"Nf3"}` (SAN or UCI) | 200 `{"player_move": MoveInfo, "bot_move": MoveInfo\|null, "state": State}`; 422 `{"detail":{"error":"invalid"\|"illegal"\|"ambiguous","message":..,"candidates":[san]}}` |
| `GET /game/{id}/state` | | `State` |
| `GET /game/{id}/hints` | | `{"phrases":["knight to f three","pawn to e four","castle kingside", ...]}`: spoken forms of every legal move, for speech-recognition contextual strings |
| `GET /game/{id}/board/read` | | `{"player":"white","pieces":{"white":{"king":["e1"],...},"black":{...}},"spoken":{"white":"king e1, queen d1, ...","black":"..."}}` |
| `POST /tts` | `{"text":"Knight to f3","voice":"af_heart","speed":1.0}` (voice, speed optional) | 200 `audio/wav` (24 kHz mono 16-bit PCM). 422 bad text/voice/speed; 503 when TTS is unavailable, so the app falls back to the on-device voice. Text is at most 300 characters. |
| `GET /tts/voices` | | `{"voices":["af_heart","bf_emma",...],"default":"af_heart"}`; 503 when unavailable |
| `POST /game/{id}/ask` | `{"question":"what is attacking e5"}` | 200 `application/x-ndjson` stream, see below. Allowed at any time, including after the game ends (post-game review). |
| `GET /game/{id}/review` | | post-game review: see below |
| `POST /game/{id}/review/{ply}/explain` | | `application/x-ndjson` stream, same events as `/ask` |
| `GET /log/summary` | | mistake-log summary: see below |
| `DELETE /game/{id}` | | 204 |

## `/say` outcomes

The server resolves the transcript to exactly one legal move, or says why not. The client never guesses.

```json
{"status":"played","player_move":MoveInfo,"bot_move":MoveInfo|null,"state":State}
{"status":"confirm","candidate":{"san":"Nf3","spoken":"Knight to f3"},"message":"Play knight to f3?"}
{"status":"ambiguous","message":"Did you mean knight to d2 or knight to f3?","candidates":[{"san":"Nbd2","spoken":"Knight b to d2"},{"san":"Nfd2","spoken":"Knight f to d2"}]}
{"status":"no_match","message":"I did not catch a legal move."}
{"status":"question","question":"why was that a mistake"}
```

- `confirm` is returned when the request had `"confirm":true` and exactly one move matched, **and also without that flag when the match needed a fix-up** (a letter that sounds like another, or an unprefixed square only a piece can reach, such as "f three" meaning the knight). Nothing is played. The app asks `message`, listens for yes or no itself, and on yes sends `POST /move` with the candidate `san`.
- After `ambiguous` the server remembers the candidates for that game. The next `/say` is matched against them first, so short answers like "f three" or "the knight from b" resolve. A played move or an unrelated transcript clears them.
- `played` with `state.game_over` true ends the game; speak `state.spoken_result` after the bot move.
- `question` means the transcript was a question, not a move (it starts with what/why/how/where/which/should/can/is/tell me/explain/analyse/...). Nothing is played. The app sends the `question` text to `POST /ask` and speaks the answer.

## `/ask` stream

One JSON object per line, flushed as soon as available:

```
{"type":"sentence","text":"Your knight on f3 is attacked by the pawn on e4."}
{"type":"sentence","text":"Move it or defend it."}
{"type":"done"}
```

- Speak each `sentence` as it arrives (each is plain text, at most about 220 characters, no markdown). Synthesise sentence n+1 while sentence n plays so there is no gap.
- Simple board questions ("what is on e4", "where is my knight", "what is attacking e5", "last five moves") are answered from the position directly in one sentence, instantly. Everything else goes to the language model with Stockfish facts attached, so the first sentence takes about 1 to 3 seconds.
- `{"type":"error","message":"..."}` may replace `done`: speak `message` (it is user-readable, e.g. "I can't reach the language model right now.") and stop. The HTTP status is still 200; 404 only for an unknown game.

## Review (milestone 6)

`GET /game/{id}/review` (allowed at any time; most useful after the game):

```json
{"summary":"You played 18 moves: 1 blunder and 1 mistake. Let's go through them.",
 "moments":[
  {"ply":6,"move_number":3,"san":"Qxf7+","spoken":"Queen takes f7, check","best_san":"Bc4",
   "best_spoken":"Bishop to c4","loss_pawns":9.4,"label":"a blunder",
   "fen_before":"...","fen_after":"...","uci":"h5f7"}
 ]}
```

- Moments are the listener's own moves that lost 1.0 pawn or more by the engine's reckoning, worst first, at most 5; if none, `moments` is empty and `summary` says so. `ply` is 1-based (ply 1 = White's first move). `fen_before` is the position the move was played from, `fen_after` the position after it; the app shows `fen_before` with `uci` highlighted while reviewing.
- `POST /game/{id}/review/{ply}/explain` streams a spoken explanation of that move in the same NDJSON format as `/ask` (sentences, then `done` or `error`). 404 for an unknown game or a ply that is not one of the game's moves.

## Mistake log

The server records, per listener, when they lose track of the board: a spoken move that clearly names a piece and destination but is not legal (`illegal_attempt`) and every "where is / what is on / what is attacking" question (`lookup`). Nothing for the app to send; it is automatic. `GET /log/summary`:

```json
{"illegal_attempts":3,"lookups":9,"by_piece":{"knight":4,"bishop":2},"by_square":{"e5":3},
 "spoken":"You asked about the board 9 times and tried 3 illegal moves. The piece you lose track of most is the knight.",
 "recent":[{"time":"2026-10-18T19:10:00Z","kind":"lookup","detail":"where is knight","game":"abc"}]}
```

The question "what are my common mistakes" (and similar) is answered from this summary by the normal `/ask` path.
