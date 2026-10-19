"""Compare AI tree ticks between a TAS recording and its playback (tas-trees.tsv, thaumiel-tas).

    python tools/tas/tree_ticks.py <recorded battle dir> <playback battle dir> [tree name filter]

tas-trees.tsv has one row per Behavior Designer tree tick: game frame, tree slot, tree id, tick number within the
frame, the seed the tick was given (reseed = tree) and Unity's random state after it. Ticks are keyed by
(id, frame, tick), which is stable between runs. For each tree this prints:
  - ticks only one run has (the tree ticked on a frame in one run and not the other),
  - the first tick whose seed differs (the seed derivation saw different frames / tick counts),
  - the first tick with the same seed but a different number of draws (the tree took a different path through
    its tasks: a non-random input such as distance, angle or a hit counter differed).
"""
import csv, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rng_draws import init, M


def draws_to(state, seed32, limit=5000):
    x, y, z, w = init(seed32)
    for n in range(limit):
        if (x, y, z, w) == state: return n
        t = (x ^ (x << 11)) & M; x, y, z = y, z, w; w = (w ^ (w >> 19) ^ t ^ (t >> 8)) & M
    return None


def load(d):
    names, ticks = {}, {}
    with open(os.path.join(d, 'tas-trees.tsv'), encoding='utf-8', errors='replace') as f:
        for r in csv.DictReader(f, delimiter='\t'):
            tid = r['id']
            if r['name']: names.setdefault(tid, r['name'])
            st = tuple(int(r[k], 16) for k in ('rng0', 'rng1', 'rng2', 'rng3'))
            seed = None if r['seed'] == '-' else int(r['seed'])
            n = draws_to(st, seed) if seed is not None else None
            ticks.setdefault(tid, {})[(int(r['game_frame']), int(r['tick']))] = (seed, n, st, r.get('via', ''))
    return names, ticks


def loads(d):
    p = os.path.join(d, 'tas-loads.tsv')
    if not os.path.exists(p): return None
    with open(p, encoding='utf-8', errors='replace') as f:
        return [(int(r['game_frame']), r['event'], int(r['request']), int(r['finished'])) for r in csv.DictReader(f, delimiter='\t')]


def main():
    rec, play = sys.argv[1], sys.argv[2]
    filt = sys.argv[3].lower() if len(sys.argv) > 3 else None
    la, lb = loads(rec), loads(play)
    if la is not None and lb is not None:
        fa = [r[:3] for r in la]; fb = [r[:3] for r in lb]
        print(f'== AI starts (frame, event, request): recording {len(la)}, playback {len(lb)}; identical: {fa == fb}')
        print(f'   recording {la[:12]}')
        print(f'   playback  {lb[:12]}')
    na, ta = load(rec); nb, tb = load(play)
    names = {**nb, **na}
    for tid in sorted(set(ta) | set(tb), key=lambda t: min(list(ta.get(t, {})) + list(tb.get(t, {})))):
        name = names.get(tid, '?')
        if filt and filt not in name.lower(): continue
        a, b = ta.get(tid, {}), tb.get(tid, {})
        print(f'== {tid} {name}: recording {len(a)} ticks, playback {len(b)}')
        last = min(max(a, default=(0, 0)), max(b, default=(0, 0)))
        only_a = sorted(k for k in a if k not in b and k <= last)
        only_b = sorted(k for k in b if k not in a and k <= last)
        if only_a: print(f'   ticks only in recording ({len(only_a)}), first: {only_a[:8]} via {[a[k][3] for k in only_a[:3]]}')
        if only_b: print(f'   ticks only in playback  ({len(only_b)}), first: {only_b[:8]} via {[b[k][3] for k in only_b[:3]]}')
        common = sorted(set(a) & set(b))
        seed_diff = next((k for k in common if a[k][0] != b[k][0]), None)
        if seed_diff: print(f'   first different seed: frame {seed_diff[0]} tick {seed_diff[1]}: {a[seed_diff][0]} vs {b[seed_diff][0]}')
        path_diff = next((k for k in common if a[k][0] == b[k][0] and a[k][2] != b[k][2]), None)
        if path_diff is None:
            print('   same draws on every common tick'); continue
        i = common.index(path_diff)
        print(f'   first different draws: frame {path_diff[0]} tick {path_diff[1]}')
        for k in common[max(0, i - 4): i + 6]:
            mark = '>>' if k == path_diff else '  '
            print(f'   {mark} frame {k[0]:>5} tick {k[1]}  draws rec {a[k][1]!s:>4}  play {b[k][1]!s:>4}  via rec {a[k][3]}  play {b[k][3]}')


if __name__ == '__main__':
    main()
