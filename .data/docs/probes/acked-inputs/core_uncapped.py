"""Core absolute pieces with no budget and no frame cap (every changed row every tick, lossless):
the bytes a viewer would need, for cases where acked_sim.py's one-frame-per-tick model caps the core.
Usage: python3 -I core_uncapped.py"""
import math, os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "compression"))
import traffic
for label, model, kw, nrec in (("shooter100p20", "shooter", dict(hz=20, players=100), 100),
                               ("tycoon10", "tycoon", dict(hz=10), 400), ("shooter60", "shooter", dict(hz=60), 30)):
    m = traffic.MODELS[model](seed=11, **kw)
    N = int(60 * m.hz)
    fr = [m.step() for _ in range(N)]
    ws = math.ceil(math.log2(nrec))
    piece = (ws + 3 + sum(f[2] for f in m.schema) + 7) // 8
    tot = 0
    for i in range(1, N):
        n = sum(1 for r in fr[i].rows if r in fr[i - 1].rows and fr[i].rows[r] != fr[i - 1].rows[r])
        if n:
            frames = math.ceil(n * piece / 955)
            tot += frames * 5 + n * piece
    print(f"{label}: piece {piece} B, {tot / 60:.0f} B/s uncapped")
