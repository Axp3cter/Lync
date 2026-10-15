"""Q2: which byte layout minimises on-wire size under engine zstd?

For each traffic model and layout: mean raw bytes per frame, then the modelled
on-wire size with engine zstd (threshold 100 B, raw fallback) at levels 1 and 3,
and the share of frames at or above the threshold.

Reliable lane: delta against the previous frame (age 1).
Unreliable lane: delta against the last acknowledged frame, ~100 ms back (age k).

Usage: PYTHONPATH=<zstandard dir> python3 sim_layout.py [frames]
"""
import sys

import traffic
from layouts import Layout, ABSOLUTE, DELTA
from wire import engine_len, zstd_len

N = int(sys.argv[1]) if len(sys.argv) > 1 else 600

CASES = [
    # (label, model, kwargs, unreliable age)
    ("shooter60", "shooter", dict(hz=60), 6),
    ("shooter20", "shooter", dict(hz=20), 2),
    ("racing60", "racing", dict(hz=60), 6),
    ("shooter100p20", "shooter", dict(hz=20, players=100), 2),
    ("mmo20", "mmo", dict(hz=20), 2),
    ("tycoon10", "tycoon", dict(hz=10), 1),
]


def measure(lay, frames, name, age, start):
    fn = getattr(lay, name)
    raws, e1, e3, z3, big = [], [], [], [], 0
    for i in range(start, len(frames)):
        b = fn(frames, i, age)
        raws.append(len(b))
        e1.append(engine_len(b, 1))
        e3.append(engine_len(b, 3))
        z3.append(zstd_len(b, 3))
        big += len(b) >= 100
    n = len(raws)
    return sum(raws) / n, sum(e1) / n, sum(e3) / n, sum(z3) / n, big / n, raws, e3


def main():
    for label, model, kw, uage in CASES:
        frames = [None]
        m = traffic.MODELS[model](seed=11, **kw)
        frames = [m.step() for _ in range(N)]
        lay = Layout(m)
        tm = traffic.MODELS[model](seed=99, **kw)
        train = [tm.step() for _ in range(min(N, 300))]
        hz = kw["hz"]
        print(f"\n=== {label}: {len(frames[-1].rows)} rows/frame, {hz} Hz "
              f"(unreliable baseline age {uage} = {1000*uage/hz:.0f} ms) ===")
        print(f"{'layout':18s} {'age':>3s} {'raw':>7s} {'eng-z1':>7s} {'eng-z3':>7s} {'zstd3':>7s} {'>=100':>6s} {'kbps(z3)':>8s}")
        start = 3 * max(uage, 1)
        for name in ABSOLUTE:
            r = measure(lay, frames, name, 1, start)
            print(f"{name:18s} {'-':>3s} {r[0]:7.1f} {r[1]:7.1f} {r[2]:7.1f} {r[3]:7.1f} {r[4]:6.0%} {r[2]*8*hz/1000:8.1f}")
        for age in sorted({1, uage}):
            lay.train_eg(train, age)
            for name in DELTA:
                if name.startswith("xor") and age != 1:
                    continue  # XOR chains are only sound on the ordered reliable lane
                r = measure(lay, frames, name, age, start)
                print(f"{name:18s} {age:3d} {r[0]:7.1f} {r[1]:7.1f} {r[2]:7.1f} {r[3]:7.1f} {r[4]:6.0%} {r[2]*8*hz/1000:8.1f}")
            # per-frame choice: bit-packed column coder raw, or byte-aligned column varints after zstd
            a = measure(lay, frames, "col_bits_pred", age, start)
            b = measure(lay, frames, "dlt_col_varint", age, start)
            pick = [min(x, y) + 0.125 for x, y in zip(a[6], b[6])]
            print(f"{'pick(colb|colv)':18s} {age:3d} {'':7s} {'':7s} {sum(pick)/len(pick):7.1f}"
                  f" {'':7s} {'':6s} {sum(pick)/len(pick)*8*hz/1000:8.1f}")


if __name__ == "__main__":
    main()
