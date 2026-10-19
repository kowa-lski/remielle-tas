"""First differences in state.tsv between a TAS recording and its playback, on exact synced frames.

    python tools/tas/state_diff.py <recorded battle dir> <playback battle dir> [count]

Every state.tsv row carries the process-wide `order` counter; tas-frames.tsv gives the counter's value at the end
of every frame, so each row gets its exact frame. Frames are `tas_frame` (counted from the sync point) when the
battle has it, else `game_frame`. Reads (get/nget) and per-frame bookkeeping (prop, bkt, fever) are left out, and
entity pointers are dropped, since they differ per run. Prints the key events (idle, first move, battle-start
notifies) side by side, then the first `count` frames whose rows differ.
"""
import bisect, collections, csv, os, sys

SKIP = {'get', 'nget', 'fever', 'prop', 'bkt'}


def load(d):
    with open(os.path.join(d, 'tas-frames.tsv'), encoding='utf-8') as f:
        fr = list(csv.DictReader(f, delimiter='\t'))
    orders = [int(r['order']) for r in fr]
    col = 'tas_frame' if fr and 'tas_frame' in fr[0] else 'game_frame'
    frames = [int(r[col]) for r in fr]
    out = collections.defaultdict(list)
    with open(os.path.join(d, 'state.tsv'), encoding='utf-8', errors='replace') as f:
        for r in csv.DictReader(f, delimiter='\t'):
            if r['kind'] in SKIP: continue
            try: o = int(r['order'])
            except (TypeError, ValueError): continue
            fno = frames[min(bisect.bisect_left(orders, o), len(frames) - 1)]
            out[fno].append((r['kind'], r['name'], r['i0'], r['i1']))
    return out, col


def main():
    rec, play = sys.argv[1], sys.argv[2]
    count = int(sys.argv[3]) if len(sys.argv) > 3 else 6
    a, ca = load(rec); b, cb = load(play)
    print(f'frames: recording {ca}, playback {cb}')
    keys = lambda d: [(f, r[0], r[1] or r[2]) for f in sorted(d) for r in d[f]
                      if r[1] in ('AFKModifier', 'WalkToRunModifier') or (r[0] == 'notify' and r[2] in ('7', '59'))][:10]
    print('key events, recording:', keys(a))
    print('key events, playback: ', keys(b))
    shown = 0
    for f in sorted(set(a) | set(b)):
        x, y = collections.Counter(a.get(f, [])), collections.Counter(b.get(f, []))
        if x == y: continue
        print(f'frame {f}: recording {sum(x.values())} rows, playback {sum(y.values())}')
        print('   only recording:', list((x - y).elements())[:6])
        print('   only playback: ', list((y - x).elements())[:6])
        shown += 1
        if shown >= count: break


if __name__ == '__main__':
    main()
