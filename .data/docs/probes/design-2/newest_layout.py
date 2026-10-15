"""Design draft 2: how should `:newest()` rows be coded? (decides review-1 B3 / redundancy 3)

Reuses the compression study's traffic models (probes/compression/traffic.py, layouts.py).
Every field of each model is treated as a `:newest()` field. Set changes (enter/leave) are
excluded: in draft 2 they travel on the reliable lane. Events are excluded. Only persisting
records are counted, so all schemes carry the same information.

Bit costs are computed exactly from the codes (no zstd: the column/row bit layouts are
incompressible, compression §2.1). Lossless channel; notify repair re-sends absolute values
in every absolute scheme alike, and grows the baseline age in the predicted ones.

Schemes, mean bytes of state per frame for one viewer:
  abs_row_byte   notify, absolute values, every newest field of each dirty record, one
                 byte-aligned chunk per record (slot id + fields): encode once per tick,
                 a viewer's frame is buffer.copy of chunks.
  abs_row_bits   the same rows bit-contiguous (no per-record padding). Not copyable with
                 buffer.copy; shown to price the padding.
  abs_col_for    notify, absolute values, per-viewer column frame-of-reference over the
                 dirty records (min + 5-bit width per column, or raw), dirty set as a bitmap
                 or EG-0 slot gaps, whichever is smaller. Per-viewer encoding, no history.
  pred_acked     column coder (zero / EG-k / sparse / raw per column) on guarded-linear
                 prediction residuals against the viewer's own acked baselines at the
                 unreliable age (~100 ms). Per-viewer encoding plus a snapshot ring per viewer.
  pred_shared    the same, but against a baseline shared by the whole audience partition,
                 aged to the slowest member (~250 ms). Encode once per partition.
  pred_age1      reference: age-1 prediction (what the reliable lane can use).

Usage: python3 -B newest_layout.py [frames]
"""
import os
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "compression"))
sys.modules.setdefault("zstandard", types.ModuleType("zstandard"))  # wire.py imports it; unused here

import traffic  # noqa: E402
from layouts import Layout, wrap  # noqa: E402
from wire import zz  # noqa: E402

N = int(sys.argv[1]) if len(sys.argv) > 1 else 600


def eg_bits(v, k):
    return 2 * ((v + (1 << k)).bit_length()) - 1 - k


def col_cost(vals, raw_bits):
    """Column coder cost in bits for zigzagged residuals (mode 2 b + k 4 b + codes)."""
    if not any(vals):
        return 2
    best = 2 + len(vals) * raw_bits
    nz = [(j, v) for j, v in enumerate(vals) if v]
    for k in range(16):
        c = 2 + 4 + sum(eg_bits(v, k) for v in vals)
        best = min(best, c)
        c2, last = 2 + 4 + eg_bits(len(nz), 0), -1
        for j, v in nz:
            c2 += eg_bits(j - last - 1, 0) + eg_bits(v - 1, k)
            last = j
        best = min(best, c2)
    return best


def for_cost(vals, raw_bits):
    if not vals:
        return 0
    lo, hi = min(vals), max(vals)
    w = (hi - lo).bit_length()
    return 1 + min(len(vals) * raw_bits, 5 + raw_bits + len(vals) * w)


def set_cost(ids, persisting, id_bits):
    """Which records a viewer's frame carries: bitmap over persisting, or EG-0 gaps."""
    if not persisting:
        return 0
    pos = {i: j for j, i in enumerate(persisting)}
    last, gaps = -1, eg_bits(len(ids), 0)
    for i in ids:
        gaps += eg_bits(pos[i] - last - 1, 0)
        last = pos[i]
    return 1 + min(len(persisting), gaps)


def run(label, model, kw, uage, sage):
    m = traffic.MODELS[model](seed=11, **kw)
    frames = [m.step() for _ in range(N)]
    lay = Layout(m)
    nf, bits = lay.nf, lay.bits
    tot = dict(abs_row_byte=0, abs_row_bits=0, abs_col_for=0, pred_acked=0, pred_shared=0, pred_age1=0)
    dirty_share, n = 0.0, 0
    start = 3 * sage + 1
    for i in range(start, len(frames)):
        f, prev = frames[i], frames[i - 1]
        persisting = [r for r in sorted(f.rows) if r in prev.rows]
        dirty = [r for r in persisting if f.rows[r] != prev.rows[r]]
        n += 1
        dirty_share += len(dirty) / max(1, len(persisting))
        rowbits = sum(bits)
        # absolute rows: count code + per record slot id + every field
        hdr = eg_bits(len(dirty), 0)
        tot["abs_row_bits"] += hdr + len(dirty) * (lay.id_bits + rowbits)
        tot["abs_row_byte"] += 8 * ((hdr + 7) // 8) + len(dirty) * 8 * ((lay.id_bits + rowbits + 7) // 8)
        # absolute column FOR, per viewer
        c = set_cost(dirty, persisting, lay.id_bits)
        for k in range(nf):
            vals = [f.rows[r][k] for r in dirty]
            c += len(vals) if bits[k] == 1 else for_cost(vals, bits[k])
        tot["abs_col_for"] += c
        # predicted column coder at three baseline ages
        for name, age in (("pred_acked", uage), ("pred_shared", sage), ("pred_age1", 1)):
            base = frames[i - age]
            ids = [r for r in persisting if r in base.rows]
            pred = lay.predict(frames, i, age)
            ds = lay.deltas(f, base, ids, pred)
            c = 0
            for k in range(nf):
                if bits[k] == 1:
                    c += col_cost([d[k] & 1 for d in ds], 1)
                else:
                    c += col_cost([zz(d[k]) for d in ds], bits[k])
            tot[name] += c
    print(f"{label:14s} rows={len(frames[-1].rows):3d} dirty={dirty_share / n:5.1%} "
          f"ages acked/shared={uage}/{sage}  " +
          "  ".join(f"{k}={v / n / 8:7.1f}" for k, v in tot.items()))


CASES = [
    ("shooter20", "shooter", dict(hz=20), 2, 5),
    ("shooter60", "shooter", dict(hz=60), 6, 15),
    ("shooter100p20", "shooter", dict(hz=20, players=100), 2, 5),
    ("racing60", "racing", dict(hz=60), 6, 15),
    ("mmo20", "mmo", dict(hz=20), 2, 5),
]

if __name__ == "__main__":
    print("mean bytes of :newest() state per frame, one viewer; see docstring")
    for case in CASES:
        run(*case)
