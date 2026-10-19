"""Compare two battle folders (a TAS recording and its playback) on the game-frame axis.

    python tools/tas/compare_runs.py <recorded battle dir> <playback battle dir> [context]

elapsed_ms is real time and differs between runs, so every row is placed on a game frame via the battle's
timescale.tsv (frame counter of the level's time manager; rows are change-only, so frames between rows are
interpolated). Entities are renamed by first appearance (E0, E1, ...), since pointers differ per run.
Prints the first frame where the random state / world clock differ (tas-frames.tsv), the first game-clock
difference (timescale.tsv) and where each attacker's hit order first differs.
"""
import bisect, csv, os, sys

def rows(path):
    with open(path, encoding='utf-8', errors='replace') as f:
        return list(csv.DictReader(f, delimiter='\t'))

def frame_map(d):
    ts = [r for r in rows(os.path.join(d, 'timescale.tsv')) if r['source'] != 'awake']
    xs = [int(r['elapsed_ms']) for r in ts]; fs = [int(r['frame']) for r in ts]
    def at(ms):
        i = bisect.bisect_right(xs, ms)
        if i == 0: return fs[0] if fs else 0
        if i >= len(xs): return fs[-1] + round((ms - xs[-1]) / 16.67)
        x0, x1, f0, f1 = xs[i - 1], xs[i], fs[i - 1], fs[i]
        return f0 + round((f1 - f0) * (ms - x0) / max(1, x1 - x0))
    return at

def entity_namer():
    seen = {}
    return lambda p: seen.setdefault(p, f'E{len(seen)}')

def hits(d):
    at = frame_map(d); name = entity_namer(); out = []
    for r in rows(os.path.join(d, 'hits.tsv')):
        if r.get('via') == 'T': continue            # TriggerAttackPattern duplicates its leaf handler row
        out.append((at(int(r['elapsed_ms'])), r['skillId'], name(r['arg1'])))
    return out

def events(d):
    at = frame_map(d); name = entity_namer(); out = []
    for r in rows(os.path.join(d, 'events.tsv')):
        out.append((at(int(r['elapsed_ms'])), r['className'], name(r['owner']), r['f0'], r['f1'], r['f2']))
    return out

def first_diff(a, b, key):
    n = min(len(a), len(b))
    for i in range(n):
        if key(a[i]) != key(b[i]): return i
    return n if len(a) != len(b) else None

def report(label, a, b, key, ctx):
    i = first_diff(a, b, key)
    print(f'== {label}: recorded {len(a)}, playback {len(b)}')
    if i is None: print('   identical'); return
    print(f'   first difference at #{i} (recorded frame ~{a[i][0] if i < len(a) else "-"}, playback frame ~{b[i][0] if i < len(b) else "-"})')
    for k in range(max(0, i - ctx), min(max(len(a), len(b)), i + ctx)):
        ra = a[k] if k < len(a) else ''; rb = b[k] if k < len(b) else ''
        mark = '  ' if k < i else '>>'
        print(f'   {mark} #{k:<5} rec {str(ra):<70} play {rb}')



def tolerant(a, b, key, tol=3):
    """First recorded row (frame order) with no unused playback row of the same key within +-tol frames, and the
    same the other way round. Ignores order within a frame and the interpolation noise of frame estimates."""
    def unmatched(x, y):
        used = [False] * len(y); by_key = {}
        for j, r in enumerate(y): by_key.setdefault(key(r), []).append(j)
        for i, r in enumerate(x):
            hit = next((j for j in by_key.get(key(r), []) if not used[j] and abs(y[j][0] - r[0]) <= tol), None)
            if hit is None: return i
            used[hit] = True
        return None
    return unmatched(a, b), unmatched(b, a)


def report_tolerant(label, a, b, key, horizon):
    a = [r for r in a if r[0] <= horizon]; b = [r for r in b if r[0] <= horizon]
    ia, ib = tolerant(a, b, key)
    print(f'== {label} (+-3 frames, up to frame {horizon})')
    print('   first recorded row missing from playback:', 'none' if ia is None else f'#{ia} {a[ia]}')
    print('   first playback row missing from recording:', 'none' if ib is None else f'#{ib} {b[ib]}')
    return ia, ib


# --- exact comparisons (no real-time interpolation) -----------------------------------------------------------

def clock(d):
    """timescale.tsv `update` rows: (frame, scale, world_s, pause) -- the game's own clock, exact per frame."""
    return {int(r['frame']): (r['scale'], r['world_s'], r['pause'])
            for r in rows(os.path.join(d, 'timescale.tsv')) if r['source'] == 'update'}


def clock_divergence(rec, play):
    """First frame where both runs logged the game clock and it differs; rows that only exist in one run before
    that are real-time artefacts (gap bookkeeping) or a moved slowdown, and are listed."""
    a, b = clock(rec), clock(play)
    last = max(b) if b else 0
    common = sorted(set(a) & set(b))
    bad = next((f for f in common if a[f] != b[f]), None)
    lim = bad if bad is not None else last
    only_a = [f for f in sorted(a) if f not in b and f < lim and f > 100]
    only_b = [f for f in sorted(b) if f not in a and f < lim and f > 100]
    return bad, last, only_a, only_b


def hit_order(d):
    """Per skill family (first 4 digits: agent / Bangboo / enemy), the skill ids in order with the frame of the last
    exact clock row before each hit."""
    clk = sorted((int(r['elapsed_ms']), int(r['frame'])) for r in rows(os.path.join(d, 'timescale.tsv')) if r['source'] == 'update')
    xs = [x for x, _ in clk]
    out = {}
    for r in rows(os.path.join(d, 'hits.tsv')):
        if r.get('via') == 'T' or r['skillId'] == '0': continue
        i = max(0, bisect.bisect_right(xs, int(r['elapsed_ms'])) - 1)
        out.setdefault(r['skillId'][:4], []).append((r['skillId'], clk[i][1] if clk else 0))
    return out


def exact_report(rec, play):
    bad, last, only_a, only_b = clock_divergence(rec, play)
    print(f'== game clock: playback reached frame {last}')
    print(f'   first frame with differing clock: {bad}')
    print(f'   slowdown rows only in recording before it: {only_a[:12]}')
    print(f'   slowdown rows only in playback  before it: {only_b[:12]}')
    ra, pa = hit_order(rec), hit_order(play)
    print('== hit order per attacker family (identical prefix, then first difference)')
    for fam in sorted(set(ra) | set(pa)):
        a, b = ra.get(fam, []), pa.get(fam, [])
        i = next((i for i in range(min(len(a), len(b))) if a[i][0] != b[i][0]), None)
        if i is None:
            print(f'   {fam}: first {min(len(a), len(b))} identical'); continue
        print(f'   {fam}: {i} identical, then rec {a[i][0]} (after clock frame {a[i][1]}) vs play {b[i][0]} (after clock frame {b[i][1]})')


# --- tas-frames.tsv (thaumiel-tas per-frame log) ---------------------------------------------------------------

def tas_frames(d):
    p = os.path.join(d, 'tas-frames.tsv')
    return rows(p) if os.path.exists(p) else None


def frames_report(rec, play):
    """First frame where Unity's random state or the world clock differs, keyed by the game's frame counter."""
    a, b = tas_frames(rec), tas_frames(play)
    if a is None or b is None:
        print('== tas-frames.tsv missing in', 'recording' if a is None else 'playback', '(needs the per-frame TAS build)'); return None
    ka = {int(r['game_frame']): r for r in a}; kb = {int(r['game_frame']): r for r in b}
    common = sorted(set(ka) & set(kb))
    rng = lambda r: (r['rng0'], r['rng1'], r['rng2'], r['rng3'])
    first_rng = next((f for f in common if rng(ka[f]) != rng(kb[f])), None)
    first_world = next((f for f in common if ka[f]['world_s'] != kb[f]['world_s']), None)
    print(f'== tas-frames.tsv: {len(a)} / {len(b)} frames, {len(common)} in both')
    print(f'   first frame with a different random state: {first_rng}')
    print(f'   first frame with a different world clock : {first_world}')
    if first_rng is not None:
        for f in [x for x in common if first_rng - 3 <= x <= first_rng + 2]:
            print(f'     frame {f}: rec {rng(ka[f])}  play {rng(kb[f])}')
    return first_rng, first_world


def order_to_frame(d):
    """Exact frame of any row carrying `order` (damage-result, state.tsv): the first frame row whose order is
    above it (that frame's step contained the row)."""
    fr = tas_frames(d)
    if fr is None: return None
    orders = [int(r['order']) for r in fr]; frames = [int(r['game_frame']) for r in fr]
    return lambda o: frames[min(bisect.bisect_left(orders, o), len(frames) - 1)]


if __name__ == '__main__':
    rec, play = sys.argv[1], sys.argv[2]
    frames_report(rec, play)            # exact, needs tas-frames.tsv (per-frame TAS build)
    exact_report(rec, play)             # game clock rows + per-attacker hit order
