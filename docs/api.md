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
| `DELETE /game/{id}` | | 204 |

## `/say` outcomes

The server resolves the transcript to exactly one legal move, or says why not. The client never guesses.

```json
{"status":"played","player_move":MoveInfo,"bot_move":MoveInfo|null,"state":State}
{"status":"confirm","candidate":{"san":"Nf3","spoken":"Knight to f3"},"message":"Play knight to f3?"}
{"status":"ambiguous","message":"Did you mean knight to d2 or knight to f3?","candidates":[{"san":"Nbd2","spoken":"Knight b to d2"},{"san":"Nfd2","spoken":"Knight f to d2"}]}
{"status":"no_match","message":"I did not catch a legal move."}
```

- `confirm` is returned when the request had `"confirm":true` and exactly one move matched, **and also without that flag when the match needed a fix-up** (a letter that sounds like another, or an unprefixed square only a piece can reach, such as "f three" meaning the knight). Nothing is played. The app asks `message`, listens for yes or no itself, and on yes sends `POST /move` with the candidate `san`.
- After `ambiguous` the server remembers the candidates for that game. The next `/say` is matched against them first, so short answers like "f three" or "the knight from b" resolve. A played move or an unrelated transcript clears them.
- `played` with `state.game_over` true ends the game; speak `state.spoken_result` after the bot move.
