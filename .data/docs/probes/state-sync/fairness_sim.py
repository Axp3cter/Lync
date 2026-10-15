"""Starvation and fairness of per-viewer schedulers under a byte budget (one viewer, newest-value records).

Records in three classes by priority weight: OWN 1 record (w=50), NEAR 30 (w=4), FAR 200 (w=0.25).
Each tick every record is dirty with probability D (its value moved). A record update costs C bytes;
the budget per tick is B bytes. Pending records coalesce (only the newest value is kept), so the backlog is
bounded by the record count. Measured: mean and p99 "age of the shown value" per class, in ticks, where age
= ticks since the record first became dirty and was not yet sent.
Schedulers:
  strict : highest static weight first (no accumulation)
  accum  : accumulator += weight while pending; send highest accumulator; reset on send (Gaffer / Iris / NfE)
  rr     : round-robin over pending records, weight ignored
  accum+floor : accum, plus any record pending > MAXAGE ticks is sent first (starvation floor)
"""
import random, statistics

CLASSES = (("own", 1, 50.0), ("near", 30, 4.0), ("far", 200, 0.25))
C, T, MAXAGE = 10, 3000, 40

def run(sched, B, D, seed):
    rng = random.Random(seed)
    recs = []
    for name, n, w in CLASSES:
        recs += [(name, w)] * n
    N = len(recs)
    pend_since = [None] * N
    acc = [0.0] * N
    ages = {c[0]: [] for c in CLASSES}
    cursor = 0
    for t in range(T):
        for i in range(N):
            if rng.random() < D and pend_since[i] is None:
                pend_since[i] = t
        pend = [i for i in range(N) if pend_since[i] is not None]
        for i in pend:
            acc[i] += recs[i][1]
        if sched == "strict":
            order = sorted(pend, key=lambda i: -recs[i][1])
        elif sched == "accum":
            order = sorted(pend, key=lambda i: -acc[i])
        elif sched == "accum+floor":
            order = sorted(pend, key=lambda i: (0 if t - pend_since[i] >= MAXAGE else 1, -acc[i]))
        else:
            order = sorted(pend, key=lambda i: (i - cursor) % N)
        budget = B
        for i in order:
            if budget < C:
                break
            budget -= C
            pend_since[i] = None
            acc[i] = 0.0
            cursor = (i + 1) % N
        for i in range(N):
            ages[recs[i][0]].append(0 if pend_since[i] is None else t - pend_since[i] + 1)
    out = {}
    for name, a in ages.items():
        a.sort()
        out[name] = (statistics.mean(a), a[int(len(a) * 0.99)], a[-1])
    return out

if __name__ == "__main__":
    print(__doc__.split("\n")[0])
    D = 0.5
    demand = sum(n for _, n, _ in CLASSES) * D * C
    print(f"dirty prob {D}: demand ~{demand:.0f} B/tick; update {C} B; {T} ticks")
    for B in (int(demand * 1.1), int(demand * 0.5), int(demand * 0.2)):
        print(f"\nbudget {B} B/tick ({B/demand:.0%} of demand)   class: mean / p99 / max age in ticks")
        for s in ("strict", "accum", "accum+floor", "rr"):
            r = run(s, B, D, 1)
            print(f"  {s:12s} " + "  ".join(f"{k}: {v[0]:6.1f} /{v[1]:4d} /{v[2]:4d}" for k, v in r.items()))
