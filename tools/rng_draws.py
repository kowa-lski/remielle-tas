"""Per-frame random draw counts from tas-frames.tsv (thaumiel-tas, reseed = frame).

    python tools/tas/rng_draws.py <recorded battle dir> <playback battle dir> <seed>

With reseed = frame the generator is set to frameSeed(seed, f) after frame f, so the state logged after frame f+1
sits `n` draws into that stream: n is how many numbers frame f+1 drew. Prints the first frames where the two runs
drew different amounts (the frames where something non-deterministic used the generator).
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compare_runs as c

M = 0xFFFFFFFF

def frame_seed(seed, frame):
    x = (seed & M) ^ ((frame * 0x9E3779B9) & M)
    x ^= x >> 16; x = (x * 0x7FEB352D) & M
    x ^= x >> 15; x = (x * 0x846CA68B) & M
    x ^= x >> 16
    return x

def init(seed):
    s = [seed & M]
    for _ in range(3): s.append((1812433253 * s[-1] + 1) & M)
    return s

def draws_to(state, seed32, limit=20000):
    x, y, z, w = init(seed32)
    for n in range(limit):
        if (x, y, z, w) == state: return n
        t = (x ^ (x << 11)) & M; x, y, z = y, z, w; w = (w ^ (w >> 19) ^ t ^ (t >> 8)) & M
    return None

def per_frame(d, seed):
    out = {}
    for r in c.tas_frames(d):
        f = int(r['game_frame']); st = tuple(int(r[k], 16) for k in ('rng0', 'rng1', 'rng2', 'rng3'))
        out[f] = draws_to(st, frame_seed(seed, f - 1)) if f > 1 else None
    return out

if __name__ == '__main__':
    rec, play, seed = sys.argv[1], sys.argv[2], int(sys.argv[3])
    a, b = per_frame(rec, seed), per_frame(play, seed)
    common = sorted(set(a) & set(b))
    unknown = [f for f in common if a[f] is None or b[f] is None][1:6]
    diff = [(f, a[f], b[f]) for f in common if a[f] != b[f] and f > 1]
    print(f'frames in both: {len(common)}; draw counts not found (more than 20000 draws, or a reseed missed): {unknown}')
    print(f'frames with different draw counts: {len(diff)}; first 25 (frame, recording, playback):')
    print('  ', diff[:25])
