"""`acked`: per-viewer predicted `:newest()` rows against acked baselines, on Lync's own rules.

One viewer per run (viewers are independent under Lync's per-viewer scheduler). Every field of each
traffic model (probes/compression/traffic.py) is a `:newest()` field; records entering the viewer's set
get a reliable catch-up add (not counted here) that resets the pair's baselines.

Server, per state tick T (v5-collections.md §5-§7):
  - a record is pending when its codes changed since the previous tick, or when a frame carrying its row
    is found lost (notify, 17-frame ring, re-pend unless a later frame carried it);
  - FIFO by pending tick (no interest, one collection), budget = state.budget / rate bytes per tick,
    rows stop at the first that does not fit (core rule); one state frame per tick here;
  - CORE: each row is a byte-aligned piece ceil((ws + 3 + sum(bits)) / 8) B, chunk header EG0(n-1)+align;
  - ACKED: one column block per frame over the selected rows in slot order: slot, gen, seg, nb
    (0 none / 1 one baseline / 2 three), a0 over nb>=1, a1 and a2 over nb==2, then one residual column
    per field: zigzag(wrap(code - prediction)) (bools: code XOR prediction). Columns use Lync's four
    modes exactly (v5.md §4.3: zero, EG-k with k:u4, sparse, frame of reference with base:EG0 width:u6).
    Header columns are ordinary integer columns (residual vs previous row).
  - Baselines: the 3 newest acked rows of the pair, ticks > T - H (history of H ticks); fewer than 3
    usable -> nb 1 (b0) if any, else 0.
  - Selection bound (exact upper bound): per row, mode-1 EG-k cost of its field residuals at k from the
    previous block's columns + the worst per-row cost of each header column; block constant 6 bits per
    column. The reference encoder's minimum over every mode and k is <= that bound.
Predictors: G = Unity GhostDeltaPredictor (guarded linear, tick-ratio fractions in 1/16, truncating
division); L = unguarded linear from b0, b1; D = b0 only (delta). Linear prediction applies to kinds
'q', 'a' (and racing's smallest-three components when the dropped index qi is equal in the row and all
baselines); other kinds predict b0.

Network: v5.md §9's default model: one-way 0.05 s + U(0, 0.02) s each way, 5% Bernoulli loss each way,
or Gilbert-Elliott bursts (mean burst 3) at 5% / 15%. Client acks (v5.md §4.1): "busy" = an upstream
unreliable frame every 1/60 s flush, the first carrying the ack when a state frame arrived since the
last ack; "idle" = ack-only frame when 2 state frames are unacked or the oldest is 100 ms old.
Checks (asserted every row): every baseline the server names is a row the client received and holds
within H ticks.

Outputs per case and scheme: B/s of state frames, rows applied per second per record, mean staleness
in ticks (T - tick of the client's newest applied row, counted only while the client's value differs
from the truth), share of rows at nb 0/1/2, and bound/actual bits.

Usage: python3 -I acked_sim.py [seconds]
"""
import math
import os
import random
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "compression"))
import traffic  # noqa: E402

SECONDS = float(sys.argv[1]) if len(sys.argv) > 1 else 60.0
BUDGET = 16000
KS = np.arange(16)


def eg0(v):
    return 2 * (v + 1).bit_length() - 1


def egk_vec(vals):
    """bits of EG-k of each value for k = 0..15: array (16, n)."""
    v = np.asarray(vals, dtype=np.float64)
    q = np.floor(v[None, :] / (2.0 ** KS[:, None])) + 1.0
    e = np.frexp(q)[1]  # bit length of q (q >= 1, exact below 2^53)
    return 2 * e - 1 + KS[:, None]


def col_cost(vals):
    """Lync column coder: fewest bits over modes 0-3 and every k; returns (bits, best mode-1 k)."""
    n = len(vals)
    if n == 0:
        return 0, 0
    if not any(vals):
        return 2, 0
    m1 = egk_vec(vals).sum(axis=1)
    k1 = int(np.argmin(m1))
    best = 6 + int(m1[k1])
    nz = [(j, v) for j, v in enumerate(vals) if v]
    gaps, last = [], -1
    for j, _ in nz:
        gaps.append(j - last - 1)
        last = j
    sp = 6 + eg0(len(nz)) + sum(eg0(g) for g in gaps) + egk_vec([v - 1 for _, v in nz]).sum(axis=1)
    best = min(best, int(sp.min()))
    lo, hi = min(vals), max(vals)
    best = min(best, 2 + eg0(lo) + 6 + n * (hi - lo).bit_length())
    return best, k1


def wrap(d, n):
    d %= n
    return d - n if d >= (n + 1) // 2 else d


def zz(v):
    return 2 * v if v >= 0 else -2 * v - 1


def trunc_div(a, b):
    q = abs(a) // b
    return q if a >= 0 else -q


def egk1(v, k):
    return 2 * ((v >> k) + 1).bit_length() - 1 + k


def jensen(m, n):
    """Upper bound on the EG-0 bits of m gaps summing to at most n - m."""
    if m == 0:
        return 0
    return math.ceil(m * (2 * math.log2(max(1.0, n / m)) + 1))


class Bound:
    """Exact upper bound on a block's bits while rows are admitted in score order (any row order)."""

    def __init__(self, ws, kprev):
        self.ws, self.kprev = ws, kprev
        self.cols = {}   # name -> [n, sum_mode1, m_nonzero, sum_sparse]
        self.total = 0
        self.pending = None

    def _col(self, cols, name, v, k):
        c = cols.setdefault(name, [0, 0, 0, 0])
        c[0] += 1
        c[1] += egk1(v, k)
        if v:
            c[2] += 1
            c[3] += egk1(v - 1, k)

    def trial(self, res, own, nb, ages, n, ref):
        cols = {name: list(c) for name, c in self.cols.items()}
        kp = self.kprev
        for k, v in enumerate(res):
            self._col(cols, ("f", k), v, kp.get(("f", k), 0))
        if own:
            self._col(cols, "nb", nb, kp.get("nb", 0))
            for i, a in enumerate(ages):
                self._col(cols, ("a0", "a1", "a2")[i], a - 1, kp.get(("a0", "a1", "a2")[i], 0))
        dif = cols.setdefault("dif", [0, 0, 0, 0])
        dif[1] += 3 + (5 + 3 if nb == 0 else 0)          # own (<= 1), gen (<= 3), seg (<= 1), EG-0
        dif[0] += 1
        self.pending = cols
        tot = 32 + eg0(n - 1) + 2 + (sum(eg0(a - 1) for a in ref[1:]) if ref[0] else 0)
        for name, (cn, s1, m, ssp) in cols.items():
            if name == "dif":
                tot += 3 * 6 + s1
                continue
            if cn == 0:
                continue
            b = 2 if m == 0 else min(6 + s1, 6 + eg0(m) + ssp + jensen(m, cn))
            tot += b
        tot += 6 + math.ceil(n * (2 * math.log2(2 * (1 << self.ws) / n + 1) + 1))   # slot gaps
        self.pending_total = tot
        return tot

    def commit(self):
        self.cols = self.pending
        self.total = self.pending_total


class Loss:
    def __init__(self, kind, p, rng):
        self.kind, self.p, self.rng, self.bad = kind, p, rng, False
        self.r_exit = 1 / 3
        self.r_enter = p * self.r_exit / (1 - p) if p < 1 else 1

    def lost(self):
        r = self.rng
        if self.kind == "bern":
            return r.random() < self.p
        self.bad = (r.random() >= self.r_exit) if self.bad else (r.random() < self.r_enter)
        return self.bad


def run(model, kw, scheme, pred="G", H=32, net=("bern", 0.05), client="busy", bound="mode1", seed=7,
        budget=BUDGET):
    m = traffic.MODELS[model](seed=11, **kw)
    hz = m.hz
    N = int(SECONDS * hz)
    frames = [m.step() for _ in range(N)]
    schema = m.schema
    nf = len(schema)
    bits = [f[2] for f in schema]
    nmod = [1 << b for b in bits]
    kinds = [f[1] for f in schema]
    linear = [k in ("q", "a") for k in kinds]
    qi_idx = next((i for i, f in enumerate(schema) if f[0] == "qi"), None)
    rot = [f[0] in ("qa", "qb", "qc") for f in schema]
    nrec = {"shooter": kw.get("players", 30), "racing": 12, "mmo": 400, "tycoon": 400}[model]
    ws = max(1, math.ceil(math.log2(nrec)))
    rowbits = sum(bits)
    piece = (ws + 3 + rowbits + 7) // 8
    per_tick = budget / hz
    rng = random.Random(seed)
    down, up = Loss(net[0], net[1], rng), Loss(net[0], net[1], rng)

    hist = {}            # (rec, tick) -> codes (shared per-tick history)
    pending = {}         # rec -> pending-since tick
    ring = []            # [seq, tick, send_time, rows]  rows: list of (rec, tick)
    acked = {}           # rec -> sorted list of acked ticks (newest last)
    reset_tick = {}      # rec -> tick of its latest catch-up add
    seq = 0
    in_flight_down = []  # (arrival, seq, tick, rows)
    in_flight_up = []    # (arrival, newest, mask)
    cl_newest = -1
    cl_received = set()
    cl_unacked = []      # (seq, arrival)
    cl_rows = {}         # rec -> (seq, tick) applied
    cl_store = {}        # rec -> set of ticks received (baseline store)
    cl_last_ack_sent = -1
    kprev = {}
    tot_bytes = 0
    rows_applied = 0
    stale_sum = 0
    stale_n = 0
    nb_count = [0, 0, 0]
    bound_bits = act_bits = 0
    clock_step = 1 / 60
    next_client = 0.0
    prev_rows = {}
    last_seq = {}        # rec -> seq of the newest frame that carried its row
    for T in range(N):
        now = T / hz
        f = frames[T]
        # client flushes up to now (acks)
        while next_client <= now:
            tc = next_client
            in_flight_down.sort()
            while in_flight_down and in_flight_down[0][0] <= tc:
                arr, s, tk, rws = in_flight_down.pop(0)
                cl_received.add(s)
                cl_unacked.append((s, arr))
                cl_newest = max(cl_newest, s)
                for (r, rt) in rws:
                    if r not in reset_tick or rt < reset_tick[r]:
                        continue
                    cl_store.setdefault(r, set()).add(rt)
                    cur = cl_rows.get(r)
                    if cur is None or s > cur[0]:
                        cl_rows[r] = (s, rt)
                        rows_applied += 1
            send = False
            if cl_unacked and cl_newest > cl_last_ack_sent:
                if client == "busy":
                    send = True
                else:
                    oldest = min(a for _, a in cl_unacked)
                    if len(cl_unacked) >= 2 or tc - oldest >= 0.1:
                        send = True
            if send:
                mask = {s for s in cl_received if cl_newest - 16 <= s <= cl_newest}
                cl_unacked = []
                cl_last_ack_sent = cl_newest
                if not up.lost():
                    in_flight_up.append((tc + 0.05 + rng.uniform(0, 0.02), cl_newest, mask))
            next_client += clock_step
        # server: process acks arrived by now
        in_flight_up.sort(key=lambda x: x[0])
        while in_flight_up and in_flight_up[0][0] <= now:
            _, newest, mask = in_flight_up.pop(0)
            keep = []
            for ent in ring:
                s, tk, st, rws = ent
                if s in mask:
                    for (r, rt) in rws:
                        if r in reset_tick and rt >= reset_tick[r]:
                            lst = acked.setdefault(r, [])
                            if rt not in lst:
                                lst.append(rt)
                                lst.sort()
                                del lst[:-3]
                elif s < newest - 16 or s <= newest:
                    for (r, rt) in rws:
                        if last_seq.get(r) == s and r in f.rows:
                            pending.setdefault(r, T)
                else:
                    keep.append(ent)
                    continue
            ring = keep
        # membership changes: catch-up adds reset baselines
        for r in f.rows:
            if r not in prev_rows:
                reset_tick[r] = T
                acked.pop(r, None)
                pending.pop(r, None)
                cl_store.pop(r, None)
                cl_rows[r] = (-1, T)
            elif f.rows[r] != prev_rows[r]:
                pending.setdefault(r, T)
        for r in list(pending):
            if r not in f.rows:
                del pending[r]
        for r in f.rows:
            hist[(r, T)] = f.rows[r]
        # staleness, before this tick's send
        for r, codes in f.rows.items():
            ap = cl_rows.get(r)
            if ap is None:
                continue
            held = hist.get((r, ap[1]))
            if held is not None and held != codes:
                stale_sum += T - ap[1]
                stale_n += 1
            else:
                stale_n += 1
        prev_rows = f.rows
        # schedule
        order = sorted(pending, key=lambda r: (pending[r], r))
        sel = []
        if scheme == "core":
            size = 0
            for r in order:
                n = len(sel) + 1
                new = 4 + (eg0(n - 1) + 7) // 8 + n * piece
                if new > per_tick or new > 1000:
                    break
                size = new
                sel.append(r)
            frame_bytes = size
        else:
            cand = []
            limit_bits = 8 * min(per_tick, 1000)
            bd = Bound(ws, kprev)
            ref = None
            for r in order:
                lst = [t for t in acked.get(r, []) if t > T - H]
                if pred == "D":
                    lst = lst[-1:]
                nb = 2 if len(lst) >= 3 and pred != "D" else (1 if lst else 0)
                if pred == "L" and len(lst) >= 2:
                    nb = 2
                codes = f.rows[r]
                b0 = b1 = b2 = None
                ages = ()
                if nb == 2:
                    t0, t1 = lst[-1], lst[-2]
                    t2 = lst[-3] if len(lst) >= 3 else t1 - 1
                    b0, b1 = hist[(r, t0)], hist[(r, t1)]
                    b2 = hist.get((r, t2))
                    ages = (T - t0, t0 - t1, t1 - t2)
                elif nb == 1:
                    t0 = lst[-1]
                    b0 = hist[(r, t0)]
                    ages = (T - t0,)
                for tk in (lst if nb else []):
                    assert tk in cl_store.get(r, set()), "named baseline not held by the client"
                res = []
                for k in range(nf):
                    c = codes[k]
                    if nb == 0:
                        p = 0
                    else:
                        p = b0[k]
                        lin = linear[k] or (rot[k] and qi_idx is not None and nb == 2 and b2 is not None and
                                            codes[qi_idx] == b0[qi_idx] == b1[qi_idx] == b2[qi_idx])
                        if nb == 2 and lin:
                            n = nmod[k]
                            d01 = wrap(b0[k] - b1[k], n)
                            af = 16 * ages[0] // ages[1]
                            if pred == "G":
                                d12 = wrap(b1[k] - b2[k], n)
                                pf = 16 * ages[1] // ages[2]
                                pb = b1[k] + trunc_div(d12 * pf, 16)
                                if abs(wrap(b0[k] - pb, n)) >= abs(d01):
                                    p = b0[k]
                                else:
                                    p = (b0[k] + trunc_div(d01 * af, 16)) % n
                            else:
                                p = (b0[k] + trunc_div(d01 * af, 16)) % n
                    if bits[k] == 1:
                        res.append(c ^ p)
                    else:
                        res.append(zz(wrap(c - p, nmod[k])))
                trip = (nb,) + ages
                if ref is None:
                    ref = trip
                own = trip != ref
                if bound == "abs":
                    newb = 32 + 8 + 8 * piece * (len(cand) + 1)
                else:
                    newb = bd.trial(res, own, nb, ages, len(cand) + 1, ref)
                if newb > limit_bits:
                    break
                if bound != "abs":
                    bd.commit()
                cand.append((r, nb, ages, res, own))
            sel = [c[0] for c in cand]
            if cand:
                bnd = bd.total if bound != "abs" else newb
                cand.sort(key=lambda c: c[0])
                tb = 32 + eg0(len(cand) - 1) + 2
                if ref[0] >= 1:
                    tb += sum(eg0(a - 1) for a in ref[1:])
                cols = {}
                prev_slot, cs = 0, []
                for c in cand:
                    cs.append(zz(wrap(c[0] - prev_slot, 1 << ws)))
                    prev_slot = c[0]
                cols["slot"] = cs
                ow, last = [], 0
                for c in cand:
                    ow.append(int(c[4]) ^ last)
                    last = int(c[4])
                cols["own"] = ow
                cols["nb"] = [c[1] for c in cand if c[4]]
                cols["a0"] = [c[2][0] - 1 for c in cand if c[4] and c[1] >= 1]
                cols["a1"] = [c[2][1] - 1 for c in cand if c[4] and c[1] == 2]
                cols["a2"] = [c[2][2] - 1 for c in cand if c[4] and c[1] == 2]
                nb0 = [c for c in cand if c[1] == 0]
                cols["gen"] = [0] * len(nb0)
                cols["seg"] = [0] * len(nb0)
                for k in range(nf):
                    cols[("f", k)] = [c[3][k] for c in cand]
                for name, vals in cols.items():
                    b, k1 = col_cost(vals)
                    tb += b
                    if vals:
                        kprev[name] = k1
                if bound != "abs":
                    assert tb <= bnd, (tb, bnd)
                frame_bytes = (tb + 7) // 8
                bound_bits += bnd
                act_bits += tb
                for c in cand:
                    nb_count[c[1]] += 1
            else:
                frame_bytes = 0
        if sel:
            rows = [(r, T) for r in sel]
            for r in sel:
                del pending[r]
                last_seq[r] = seq
            ring.append([seq, T, now, rows])
            while len(ring) > 17:
                old = ring.pop(0)
                for (r, rt) in old[3]:
                    if last_seq.get(r) == old[0] and r in f.rows:
                        pending.setdefault(r, T)
            if not down.lost():
                in_flight_down.append((now + 0.05 + rng.uniform(0, 0.02), seq, T, rows))
            seq += 1
            tot_bytes += frame_bytes
    nrec_mean = sum(len(fr.rows) for fr in frames) / N
    return dict(Bps=tot_bytes / SECONDS, hz_per_rec=rows_applied / SECONDS / nrec_mean,
                stale=stale_sum / max(1, stale_n), nb=nb_count, bound=bound_bits, act=act_bits)


CASES = [
    ("shooter20", "shooter", dict(hz=20)),
    ("shooter60", "shooter", dict(hz=60)),
    ("shooter100p20", "shooter", dict(hz=20, players=100)),
    ("racing60", "racing", dict(hz=60)),
    ("mmo20", "mmo", dict(hz=20)),
    ("tycoon10", "tycoon", dict(hz=10)),
]


def fmt(label, r):
    nbt = sum(r["nb"]) or 1
    nbs = "/".join(f"{x / nbt:.0%}" for x in r["nb"])
    ub = f" bound/actual {r['bound'] / r['act']:.2f}" if r["act"] else ""
    return (f"  {label:28s} {r['Bps']:8.0f} B/s  rows/s/rec {r['hz_per_rec']:6.2f}  stale {r['stale']:6.3f}"
            f"  nb0/1/3 {nbs}{ub}")


if __name__ == "__main__":
    which = os.environ.get("PART", "all")
    print(f"acked_sim: {SECONDS:.0f} s per run, budget {BUDGET} B/s, seed 7; see docstring")
    for label, model, kw in CASES:
        print(label)
        if which in ("all", "main"):
            print(fmt("core absolute pieces", run(model, kw, "core")))
            for pred in ("G", "L", "D"):
                print(fmt(f"acked {pred} H32 busy bern5", run(model, kw, "acked", pred=pred)))
            print(fmt("acked G H32 idle bern5", run(model, kw, "acked", client="idle")))
            print(fmt("acked G H32 bound=piece width", run(model, kw, "acked", bound="abs")))
        if which in ("all", "hist"):
            for H in (8, 16, 64, 255):
                print(fmt(f"acked G H{H}", run(model, kw, "acked", H=H)))
        if which in ("all", "loss"):
            for net in (("ge", 0.05), ("ge", 0.15)):
                print(fmt(f"core {net[0]}{int(net[1]*100)}", run(model, kw, "core", net=net)))
                print(fmt(f"acked G H32 {net[0]}{int(net[1]*100)}", run(model, kw, "acked", net=net)))
        if which in ("all", "nobudget"):
            print(fmt("core, no budget", run(model, kw, "core", budget=10 ** 9)))
            print(fmt("acked G, no budget", run(model, kw, "acked", budget=10 ** 9)))
