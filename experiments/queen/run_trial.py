#!/usr/bin/env python3
"""QUEEN trial harness (experiment; nothing in server/ depends on it).

For one model directory and one --gpu-memory-utilization value it runs every position
in positions.json through the model, then scores each answer against Stockfish (CPU,
1 s, multipv 5; top-3 is the first three lines) and python-chess, and writes
results-<model>-<util>.json next to this file.

Run it with the model's venv python (it already has python-chess; the harness itself
never imports torch/vllm):

    queen_pawn-8/.venv/bin/python run_trial.py --model-dir queen_pawn-8 --util 0.5

Modes
  persistent (default)  queen_worker.py loads the model once; load time and per-answer
                        time are recorded separately. Same generator/sampling/move
                        policy as infer.py.
  cli                   unmodified infer.py once per position; the time is the whole
                        process (cold start + answer), they can't be separated.

Non-GPU self-test (no model touched, no GPU used):
    queen_pawn-8/.venv/bin/python run_trial.py --model-dir queen_pawn-8 --util 0.5 --fake
"""
import argparse
import collections
import datetime
import json
import os
import re
import shutil
import signal
import statistics
import subprocess
import sys
import time
from pathlib import Path

import chess
import chess.engine

HERE = Path(__file__).resolve().parent
DEFAULT_STOCKFISH = Path('/home/louis/code/VoiceChess/server/engines/bin/stockfish')
SF_MULTIPV = 5
TOKEN_MOVE = re.compile(
    r"<PIECE_(?P<mover_side>[MO])(?P<mover_piece>[PNBRQK])>\s*"
    r"<SQUARE_(?P<source>\d+)>\s*"
    r"(?:<PIECE_(?P<captured_side>[MO])(?P<captured_piece>[PNBRQK])>\s*)?"
    r"<SQUARE_(?P<target>\d+)>"
    r"(?:<PIECE_(?P<promotion_side>[MO])(?P<promotion_piece>[QRBN])>)?")
FIELDS = re.compile(
    r"(?ms)^(?P<name>ANALYSIS|BEST_MOVE|CRITICAL_LINE|PROMISING_MOVES|EVALUATION):"
    r"\s*(?P<body>.*?)(?=^(?:ANALYSIS|BEST_MOVE|CRITICAL_LINE|PROMISING_MOVES|EVALUATION):|\Z)")
PIECE_TYPES = {'P': chess.PAWN, 'N': chess.KNIGHT, 'B': chess.BISHOP,
               'R': chess.ROOK, 'Q': chess.QUEEN, 'K': chess.KING}
PROMOS = {'Q': chess.QUEEN, 'R': chess.ROOK, 'B': chess.BISHOP, 'N': chess.KNIGHT}


# --------------------------------------------------------------------- Stockfish

def score_dict(score):
    w = score.white()
    return {'cp': w.score(), 'mate': w.mate()}


def stockfish_analysis(positions, sf_path, seconds, cache_path):
    """Top-SF_MULTIPV lines per position (white-POV scores), cached on disk."""
    cache = json.loads(cache_path.read_text()) if cache_path.exists() else {}
    engine = None
    out = {}
    try:
        for pos in positions:
            key = f"{pos['fen']}|{seconds}|{SF_MULTIPV}"
            if key not in cache:
                if engine is None:
                    engine = chess.engine.SimpleEngine.popen_uci(str(sf_path))
                    engine.configure({'Threads': 2, 'Hash': 64})
                board = chess.Board(pos['fen'])
                infos = engine.analyse(board, chess.engine.Limit(time=seconds),
                                       multipv=SF_MULTIPV)
                lines = []
                for info in infos:
                    pv = info['pv']
                    lines.append({'uci': pv[0].uci(), 'san': board.san(pv[0]),
                                  'score': score_dict(info['score']),
                                  'pv_uci': [m.uci() for m in pv[:6]]})
                cache[key] = lines
            out[pos['id']] = cache[key]
    finally:
        if engine is not None:
            engine.quit()
    cache_path.write_text(json.dumps(cache, indent=1))
    return out


# ----------------------------------------------------------------- move parsing

def decode_token_move(atom, board, pov):
    """POV-token move -> (chess.Move | None, problem | None). Legal on `board`."""
    s, t = int(atom.group('source')) - 1, int(atom.group('target')) - 1
    if not (0 <= s < 64 and 0 <= t < 64):
        return None, 'square out of range'
    if pov == chess.BLACK:
        s ^= 56
        t ^= 56
    promo = PROMOS.get(atom.group('promotion_piece'))
    piece = board.piece_at(s)
    if promo is None and piece and piece.piece_type == chess.PAWN \
            and chess.square_rank(t) in (0, 7):
        promo = chess.QUEEN
    move = chess.Move(s, t, promotion=promo)
    if move not in board.legal_moves:
        return move, 'illegal'
    return move, None


def fields_of(raw):
    return {m.group('name'): m.group('body').strip() for m in FIELDS.finditer(raw)}


def check_explanation(board, raw, sf_lines):
    """Crude automatic spot-check of the structured output against Stockfish.

    Flags (strings) for: the BEST_MOVE or any PROMISING_MOVES entry that is illegal or
    outside Stockfish's top 5; a CRITICAL_LINE whose replay hits an illegal move, or
    whose first move is outside the top 5. Moves in ANALYSIS prose may legitimately
    belong to hypothetical lines, so they are only counted (soft), never flagged.
    Not a judgement of whether the explanation is *true*; the human spot-check does that.
    """
    top5 = {l['uci'] for l in sf_lines[:5]}
    pov = board.turn
    fields = fields_of(raw)
    flags = []
    soft = {}
    mention_count = 0

    def root_moves(name):
        res = []
        for atom in TOKEN_MOVE.finditer(fields.get(name, '')):
            res.append(decode_token_move(atom, board, pov))
        return res

    best = root_moves('BEST_MOVE')
    if not fields.get('BEST_MOVE'):
        flags.append('no_best_move_field')
    for move, problem in best[:1]:
        mention_count += 1
        if problem:
            flags.append(f'best_move_illegal:{move.uci()}')
        elif move.uci() not in top5:
            flags.append(f'best_move_not_top5:{move.uci()}')
    for move, problem in root_moves('PROMISING_MOVES'):
        mention_count += 1
        if problem:
            flags.append(f'promising_illegal:{move.uci()}')
        elif move.uci() not in top5:
            flags.append(f'promising_not_top5:{move.uci()}')

    # critical line: replay from the root
    line_board = board.copy(stack=False)
    for ply, atom in enumerate(TOKEN_MOVE.finditer(fields.get('CRITICAL_LINE', '')), 1):
        mention_count += 1
        move, problem = decode_token_move(atom, line_board, pov)
        if problem:
            flags.append(f'critical_line_illegal_at_ply_{ply}:{move.uci()}')
            break
        if ply == 1 and move.uci() not in top5:
            flags.append(f'critical_line_first_move_not_top5:{move.uci()}')
        line_board.push(move)
        if line_board.is_game_over():
            break
    if not fields.get('CRITICAL_LINE'):
        flags.append('no_critical_line_field')

    analysis_illegal = 0
    analysis_total = 0
    for atom in TOKEN_MOVE.finditer(fields.get('ANALYSIS', '')):
        analysis_total += 1
        _, problem = decode_token_move(atom, board, pov)
        analysis_illegal += bool(problem)
    soft['analysis_move_mentions'] = analysis_total
    soft['analysis_mentions_not_legal_at_root'] = analysis_illegal
    if mention_count + analysis_total == 0:
        flags.append('no_parseable_move_tokens')
    return {'flags': flags, 'soft': soft, 'structured_mentions': mention_count}


def own_best_move(board, raw):
    """The model's BEST_MOVE as written (before infer.py's random fallback)."""
    body = fields_of(raw).get('BEST_MOVE', '')
    atom = TOKEN_MOVE.search(body)
    if not atom:
        return None, 'unparseable'
    move, problem = decode_token_move(atom, board, board.turn)
    return move.uci(), problem or 'legal'


# ------------------------------------------------------------------ model runs

def vram_snapshot():
    try:
        out = subprocess.run(
            ['nvidia-smi', '--query-gpu=memory.used,memory.total', '--format=csv,noheader,nounits'],
            capture_output=True, text=True, timeout=20).stdout.strip().split(',')
        return {'used_mib': int(out[0]), 'total_mib': int(out[1])}
    except Exception as exc:  # noqa: BLE001 - best effort metadata
        return {'error': str(exc)}


def kill_group(proc):
    try:
        os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(timeout=20)
    except Exception:  # noqa: BLE001
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except Exception:  # noqa: BLE001
            pass


def error_excerpt(log_path, n=12):
    lines = [l for l in log_path.read_text(errors='replace').splitlines() if l.strip()]
    hits = [l for l in lines if re.search(r'OutOfMemory|out of memory|Error|Exception|memory', l)]
    return '\n'.join((hits[-n:] if hits else lines[-n:]))


def run_persistent(model_dir, util, positions, args, log_path, rows_path):
    rows_path.unlink(missing_ok=True)
    pos_path = rows_path.with_suffix('.positions.json')
    pos_path.write_text(json.dumps(positions))
    py = model_dir / '.venv' / 'bin' / 'python'
    cmd = [str(py), str(HERE / 'queen_worker.py'), '--model-dir', str(model_dir),
           '--positions', str(pos_path), '--out', str(rows_path),
           '--gpu-memory-utilization', str(util), '--max-tokens', str(args.max_tokens)]
    env = dict(os.environ, CUDA_VISIBLE_DEVICES='0')
    with open(log_path, 'w') as log:
        proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, env=env,
                                start_new_session=True)
    start = last = time.monotonic()
    seen = 0
    loaded = None
    answers = {}
    while True:
        time.sleep(1.0)
        rows = [json.loads(l) for l in rows_path.read_text().splitlines()] if rows_path.exists() else []
        if len(rows) > seen:
            seen, last = len(rows), time.monotonic()
        for r in rows:
            if r['event'] == 'loaded':
                loaded = r
            elif r['event'] in ('answer', 'error'):
                answers[r['id']] = r
        done = len(answers) == len(positions)
        timeout = args.answer_timeout if loaded else args.load_timeout
        if done or proc.poll() is not None or time.monotonic() - last > timeout:
            break
    timed_out = not done and proc.poll() is None
    if proc.poll() is None:
        kill_group(proc)
    if loaded is None:
        reason = 'timeout waiting for model load' if timed_out else f'worker exited {proc.returncode} before loading'
        return {'ok': False, 'error': reason + '\n' + error_excerpt(log_path)}, {}
    return {'ok': True, **{k: v for k, v in loaded.items() if k != 'event'},
            'wall_to_loaded_s': time.monotonic() - start}, answers


def run_cli(model_dir, util, positions, args, log_path):
    py = model_dir / '.venv' / 'bin' / 'python'
    env = dict(os.environ, CUDA_VISIBLE_DEVICES='0')
    answers = {}
    load = {'ok': None}
    for pos in positions:
        cmd = [str(py), str(model_dir / 'infer.py'), '--fen', pos['fen'],
               '--gpu-memory-utilization', str(util), '--max-tokens', str(args.max_tokens)]
        t = time.perf_counter()
        with open(log_path, 'a') as log:
            log.write(f"\n===== {pos['id']} =====\n")
            log.flush()
            proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=log, env=env, text=True,
                                  timeout=args.load_timeout + args.answer_timeout)
        wall = time.perf_counter() - t
        text = proc.stdout
        data = None
        for m in reversed(list(re.finditer(r'^\{$', text, re.M))):
            try:
                data, _ = json.JSONDecoder().raw_decode(text[m.start():])
                break
            except json.JSONDecodeError:
                continue
        if data is None:
            answers[pos['id']] = {'event': 'error', 'id': pos['id'], 'wall_s': wall,
                                  'error': error_excerpt(log_path)}
            load['ok'] = load['ok'] or False
            continue
        load['ok'] = True
        answers[pos['id']] = {'event': 'answer', 'id': pos['id'], 'wall_s': wall, **data}
    return load, answers


# -------------------------------------------------------------------- fake mode

def move_tokens(board, move, pov):
    def sq(s):
        return (s ^ 56 if pov == chess.BLACK else s) + 1
    piece = board.piece_at(move.from_square)
    side = lambda color: 'M' if color == pov else 'O'  # noqa: E731
    tok = f'<PIECE_{side(piece.color)}{piece.symbol().upper()}><SQUARE_{sq(move.from_square)}>'
    if board.is_capture(move):
        cap = chess.Piece(chess.PAWN, not board.turn) if board.is_en_passant(move) \
            else board.piece_at(move.to_square)
        tok += f'<PIECE_{side(cap.color)}{cap.symbol().upper()}>'
    tok += f'<SQUARE_{sq(move.to_square)}>'
    if move.promotion:
        tok += f"<PIECE_{side(piece.color)}{chess.piece_symbol(move.promotion).upper()}>"
    return tok


def fake_answers(positions, sf):
    """Synthetic worker output exercising each branch of the checker."""
    answers = {}
    for i, pos in enumerate(positions):
        board = chess.Board(pos['fen'])
        pov = board.turn
        lines = sf[pos['id']]
        case = i % 6
        if case == 3:       # an illegal move: a piece that isn't there
            bad = chess.Move(chess.A1, chess.A8)
            while bad in board.legal_moves or board.piece_at(bad.from_square) is None:
                bad = chess.Move(bad.from_square, (bad.to_square + 7) % 64)
            best_tok = f'<PIECE_MR><SQUARE_{bad.from_square + 1}><SQUARE_{bad.to_square + 1}>'
            best_move = None
        elif case == 4:     # legal but outside the top 5
            top5 = {l['uci'] for l in lines}
            worst = [m for m in board.legal_moves if m.uci() not in top5]
            best_move = worst[-1] if worst else chess.Move.from_uci(lines[-1]['uci'])
            best_tok = move_tokens(board, best_move, pov)
        elif case == 2:     # third-best
            best_move = chess.Move.from_uci(lines[min(2, len(lines) - 1)]['uci'])
            best_tok = move_tokens(board, best_move, pov)
        else:
            best_move = chess.Move.from_uci(lines[0]['uci'])
            best_tok = move_tokens(board, best_move, pov)
        if case == 5:       # unparseable output -> random legal fallback
            raw, source = 'I think the position is roughly equal.', 'random_legal_fallback'
            uci = sorted(m.uci() for m in board.legal_moves)[0]
        else:
            crit = []
            lb = board.copy(stack=False)
            line = [best_move] if best_move else []
            if case == 3:
                line = []
            else:
                for u in lines[0]['pv_uci'][1:4] if case in (0, 1) else []:
                    line.append(chess.Move.from_uci(u))
            for m in line:
                if m not in lb.legal_moves:
                    break
                crit.append(move_tokens(lb, m, pov))
                lb.push(m)
            promising = ' '.join(move_tokens(board, chess.Move.from_uci(l['uci']), pov)
                                 for l in lines[1:3])
            raw = (f'ANALYSIS:\nThe key idea is {best_tok}.\nBEST_MOVE:\n{best_tok}\n'
                   f'CRITICAL_LINE:\n{" ".join(crit)}\nPROMISING_MOVES:\n{promising}\n'
                   f'EVALUATION:\n+0.2 from <WHITE> perspective.')
            if case == 3:
                uci, source = sorted(m.uci() for m in board.legal_moves)[0], 'random_legal_fallback'
            else:
                uci, source = best_move.uci(), 'best_move'
        answers[pos['id']] = {'event': 'answer', 'id': pos['id'], 'gen_s': 1.0 + 0.1 * i,
                              'raw_text': raw, 'text': raw, 'best_move_uci': uci,
                              'move_source': source, 'finish_reason': 'stop',
                              'generated_tokens': len(raw.split())}
    return {'ok': True, 'load_s': 0.0, 'fake': True}, answers


# ---------------------------------------------------------------- scoring/summary

def score_position(pos, sf_lines, ans):
    board = chess.Board(pos['fen'])
    rec = {'id': pos['id'], 'category': pos['category'], 'fen': pos['fen'],
           'stockfish_top': [{'san': l['san'], 'uci': l['uci'], 'score': l['score']} for l in sf_lines]}
    if ans is None or ans.get('event') == 'error':
        rec.update({'answered': False, 'error': (ans or {}).get('error', 'no answer (worker stopped)')})
        return rec
    uci = ans.get('best_move_uci')
    try:
        move = chess.Move.from_uci(uci) if uci else None
    except ValueError:
        move = None
    top = [l['uci'] for l in sf_lines]
    raw = ans.get('raw_text', '')
    own, own_state = own_best_move(board, raw)
    rec.update({
        'answered': True,
        'answer_time_s': ans.get('gen_s'),
        'wall_time_s': ans.get('wall_s'),
        'returned_move': uci,
        'returned_move_san': board.san(move) if move and move in board.legal_moves else None,
        'legal': bool(move and move in board.legal_moves),
        'in_top1': uci == top[0] if uci else False,
        'in_top3': uci in top[:3] if uci else False,
        'in_top5': uci in top[:5] if uci else False,
        'move_source': ans.get('move_source'),
        'model_own_best_move': own,
        'model_own_best_move_state': own_state,
        'finish_reason': ans.get('finish_reason'),
        'generated_tokens': ans.get('generated_tokens'),
        'explanation': ans.get('text'),
        'raw_text': raw,
        'sanity': check_explanation(board, raw, sf_lines),
    })
    return rec


def summarise(recs, load):
    answered = [r for r in recs if r.get('answered')]
    n = len(recs)
    times = [r['answer_time_s'] for r in answered if r.get('answer_time_s') is not None]
    walls = [r['wall_time_s'] for r in answered if r.get('wall_time_s') is not None]
    model_sourced = [r for r in answered if r['move_source'] == 'best_move']
    flagged = [r for r in answered if r['sanity']['flags']]
    flag_kinds = collections.Counter(f.split(':')[0].split('_at_ply')[0]
                                     for r in answered for f in r['sanity']['flags'])
    pct = lambda a, b: (round(100 * a / b, 1) if b else None)  # noqa: E731
    return {
        'loaded_ok': load.get('ok'),
        'positions': n, 'answered': len(answered),
        'legal': sum(r['legal'] for r in answered),
        'legal_pct_of_answered': pct(sum(r['legal'] for r in answered), len(answered)),
        'model_move_source_best_move': len(model_sourced),
        'fallback_moves': sum(r['move_source'] == 'random_legal_fallback' for r in answered),
        'top1': sum(r['in_top1'] for r in answered),
        'top3': sum(r['in_top3'] for r in answered),
        'top3_pct_of_answered': pct(sum(r['in_top3'] for r in answered), len(answered)),
        'top3_among_model_sourced_best_move': sum(r['in_top3'] for r in model_sourced),
        'answer_time_s_median': round(statistics.median(times), 2) if times else None,
        'answer_time_s_median_excl_first': round(statistics.median(times[1:]), 2) if len(times) > 1 else None,
        'answer_time_s_max': round(max(times), 2) if times else None,
        'answers_under_5s': sum(t < 5 for t in times),
        'wall_time_s_median': round(statistics.median(walls), 2) if walls else None,
        'explanations_flagged': len(flagged),
        'flag_kinds': dict(flag_kinds),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--model-dir', type=Path, required=True)
    ap.add_argument('--util', type=float, required=True, help='--gpu-memory-utilization value')
    ap.add_argument('--mode', choices=['persistent', 'cli'], default='persistent')
    ap.add_argument('--positions', type=Path, default=HERE / 'positions.json')
    ap.add_argument('--stockfish', type=Path, default=DEFAULT_STOCKFISH)
    ap.add_argument('--sf-seconds', type=float, default=1.0)
    ap.add_argument('--max-tokens', type=int, default=2048)
    ap.add_argument('--limit', type=int, help='only the first N positions')
    ap.add_argument('--load-timeout', type=float, default=900, help='s without progress while loading')
    ap.add_argument('--answer-timeout', type=float, default=300, help='s without a new answer')
    ap.add_argument('--out-dir', type=Path, default=HERE)
    ap.add_argument('--fake', action='store_true',
                    help='non-GPU self-test: synthetic model output, writes results-FAKE-*.json')
    args = ap.parse_args()

    model_dir = args.model_dir.resolve()
    name = model_dir.name
    positions = json.loads(args.positions.read_text())
    if args.limit:
        positions = positions[:args.limit]
    for p in positions:
        assert chess.Board(p['fen']).is_valid(), p['id']

    (args.out_dir / 'logs').mkdir(exist_ok=True)
    sf = stockfish_analysis(positions, args.stockfish, args.sf_seconds,
                            args.out_dir / 'stockfish-cache.json')
    meta = {'model': name, 'util': args.util, 'mode': 'fake' if args.fake else args.mode,
            'date': datetime.datetime.now().isoformat(timespec='seconds'),
            'stockfish': {'seconds': args.sf_seconds, 'multipv': SF_MULTIPV,
                          'version': 'see engine banner', 'path': str(args.stockfish)},
            'max_tokens': args.max_tokens}
    tag = f'{"FAKE-" if args.fake else ""}{name}-{args.util}'
    log_path = args.out_dir / 'logs' / f'{tag}.log'
    if args.fake:
        load, answers = fake_answers(positions, sf)
    else:
        meta['vram_before'] = vram_snapshot()
        log_path.unlink(missing_ok=True)
        if args.mode == 'persistent':
            load, answers = run_persistent(model_dir, args.util, positions, args, log_path,
                                           args.out_dir / 'logs' / f'{tag}.rows.jsonl')
        else:
            load, answers = run_cli(model_dir, args.util, positions, args, log_path)
        meta['vram_after'] = vram_snapshot()
    recs = [score_position(p, sf[p['id']], answers.get(p['id'])) for p in positions]
    result = {'meta': meta, 'load': load, 'summary': summarise(recs, load), 'positions': recs}
    out = args.out_dir / f'results-{tag}.json'
    out.write_text(json.dumps(result, indent=2, ensure_ascii=False))
    print(json.dumps(result['summary'], indent=2))
    print('wrote', out)


if __name__ == '__main__':
    main()
