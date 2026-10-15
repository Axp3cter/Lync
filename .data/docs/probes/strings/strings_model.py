"""strings: downstream string tables on the compression study's traffic models (research/strings.md).

Reuses probes/compression/traffic.py unchanged (same seeds and lengths as sim_strings.py: seed 51; tycoon 3000
frames at 10 Hz, mmo and shooter 3000 frames at 20 Hz). Counts, per recipient, the bits of string values in Lync's
wire (v5.md §4: lengths u(ceil(log2(max+1))) in the bit section, bytes in the tail), structured as events rather than
formatted text (compression §5's templates), for:
  inline    t.string(max) every time
  interned  t.string(max):intern(T): value = entry:u1, then id:u(w) (entry) or the plain t.string form (literal);
            definitions in the viewer's strings chunk: per table count:EG0, then per definition id:u(w) len:u(Lt),
            bytes in the tail; plus the chunk's framing (below)
Framing charged to interned, per frame carrying definitions: the strings chunk lives in a state segment of
namespace 0 (which has no collections), so: the chunk's namespace index (EG0 of 1 = 3 bits), EG0 of each table's
definition count, 3.5 bits of mean alignment padding (chunks start on a byte, residue assumed uniform), and the toc
change: namespace 0's segment entry (ns EG0(0) = 1 bit, count-1 EG0(0) = 1 bit) and segs(state)'s n + 1 (events-only
frame: EG0(0) -> EG0(1), +2 bits; a frame already holding the namespace's state segment: EG0(1) -> EG0(2), +0 bits).
Frames without definitions carry nothing new.
Bytes = bits / 8 (expected value; the frame rounds once).
Usage: python3 -B strings_model.py   (no zstd needed: compression §5 found zstd adds nothing at these sizes)
"""
import math
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "compression"))
import traffic  # noqa: E402


def u(maxv):
    return math.ceil(math.log2(maxv + 1))


def eg0(n):
    return 2 * int(math.floor(math.log2(n + 1))) + 1


ALIGN = 3.5


class Viewer:
    def __init__(self):
        self.held = set()


def frame_cost(values, viewer, tables, ns_has_collections, w_of):
    """values: list of (table or None, maxBytes, string). Returns (inline_bits, interned_bits, defs list)."""
    inline = interned = 0
    defs = {}
    for tbl, mx, s in values:
        b = len(s.encode())
        inline += u(mx) + 8 * b
        if tbl is None:
            interned += u(mx) + 8 * b
            continue
        interned += 1 + w_of[tbl]
        if s not in viewer.held and s not in defs.get(tbl, {}):
            defs.setdefault(tbl, {})[s] = b
    if defs:
        hdr = ALIGN + 3 + 1 + 1
        hdr += 0 if ns_has_collections else 2
        for tbl in tables:
            hdr += eg0(len(defs.get(tbl, {})))
        interned += hdr
        for tbl, d in defs.items():
            for s, b in d.items():
                interned += w_of[tbl] + tables[tbl] + 8 * b
                viewer.held.add(s)
    return inline, interned, defs


def run(name, model, hz, frames, mapper, tables, ns_has_collections, w_of):
    m = traffic.MODELS[model](hz=hz, seed=51)
    v = Viewer()
    tot_in = tot_int = 0.0
    ss_in = ss_int = 0.0
    nd = ndframes = nref = 0
    table_bytes = {t: 0 for t in tables}
    entries = {t: set() for t in tables}
    first = None
    for i in range(frames):
        f = m.step()
        vals = mapper(f)
        a, b, defs = frame_cost(vals, v, tables, ns_has_collections, w_of)
        if i == 0:
            first = (a, b, sum(len(d) for d in defs.values()))
        tot_in += a
        tot_int += b
        if i > 0:
            ss_in += a
            ss_int += b
        nref += sum(1 for t, _, _ in vals if t is not None)
        if defs:
            ndframes += 1
        for t, d in defs.items():
            nd += len(d)
            for s, by in d.items():
                if s not in entries[t]:
                    entries[t].add(s)
                    table_bytes[t] += by
    secs = frames / hz
    print(f"\n## {name}: {model} @ {hz} Hz, {secs:.0f} s, one recipient")
    print(f"  string values per second: {nref / secs:.2f} interned; definitions {nd} in {ndframes} frames")
    print(f"  inline   {tot_in / 8 / secs:8.2f} B/s")
    print(f"  interned {tot_int / 8 / secs:8.2f} B/s   saved {(tot_in - tot_int) / 8 / secs:7.2f} B/s"
          f" ({100 * (1 - tot_int / tot_in):.1f}%)")
    print(f"  steady state (frame 0, the join catch-up, excluded): inline {ss_in / 8 / secs:.2f} B/s,"
          f" interned {ss_int / 8 / secs:.2f} B/s")
    for t in tables:
        print(f"  table {t}: {len(entries[t])} entries, {table_bytes[t]} B of strings, w = {w_of[t]}")
    print(f"  first frame: inline {first[0] / 8:.1f} B, interned {first[1] / 8:.1f} B ({first[2]} definitions)")
    return entries, table_bytes


KILL = re.compile(r"^(.+) eliminated (.+)$")
NOTIFY = re.compile(r"^(.+) upgraded to level (\d+)!$")


def shooter_map(tbl):
    def f(fr):
        out = []
        for ctx, s in fr.strings:
            a, b = KILL.match(s).groups()
            out += [(tbl, 20, a), (tbl, 20, b)]
        return out
    return f


def mmo_map(tbl):
    return lambda fr: [(tbl, 20, s) for ctx, s in fr.strings]


def tycoon_map(tbl):
    def f(fr):
        out = []
        for ctx, s in fr.strings:
            if ctx == "notify":
                item, _ = NOTIFY.match(s).groups()
                out.append((tbl, 32, item))
                out.append((None, 255, ""))  # level t.int(1, 255): u(8), the same on both sides; no bytes
            elif ctx in ("label", "purchase"):
                out.append((tbl, 32, s))
            else:
                out.append((None, 200, s))  # chat t.string(200): never interned
        return out
    return f


def column_ids(model, hz, maxEntries):
    """The join catch-up: ids of the first frame's adds as one column (v5.md §4.3 modes 1 and 3, best k/width),
    with ids drawn at random among free ids against ids in creation order."""
    import random
    m = traffic.MODELS[model](hz=hz, seed=51)
    f = m.step()
    names = [s for _, s in f.strings]
    order = {}
    for s in names:
        order.setdefault(s, len(order))
    rng = random.Random(7)
    rnd_ids = dict(zip(order, rng.sample(range(maxEntries), len(order))))
    n = maxEntries

    def cost(ids):
        prev, res = 0, []
        for x in ids:
            r = (x - prev) % n
            if r >= (n + 1) // 2:
                r -= n
            res.append(2 * r if r >= 0 else -2 * r - 1)
            prev = x
        best = None
        for k in range(16):
            bits = 2 + 4 + sum(eg0(z >> k) + k for z in res)
            best = bits if best is None else min(best, bits)
        lo, hi = min(res), max(res)
        width = 0 if hi == lo else math.ceil(math.log2(hi - lo + 1))
        forb = 2 + eg0(lo) + 6 + width * len(res)
        return min(best, forb)

    seq = cost([order[s] for s in names])
    rnd = cost([rnd_ids[s] for s in names])
    single = len(names) * (1 + math.ceil(math.log2(maxEntries)))
    print(f"  catch-up ids column, {len(names)} adds, maxEntries {maxEntries}: creation-order ids {seq} bits,"
          f" random ids {rnd} bits, single rows {len(names) * math.ceil(math.log2(maxEntries))} bits"
          f" (+{len(names)} entry bits each way)")


if __name__ == "__main__":
    for W in (64, 4096):
        w = math.ceil(math.log2(W))
        print(f"\n# maxEntries {W} (w = {w}) for names; items table maxEntries {max(256, W)}")
        run("shooter kill feed, kill { killer, victim: t.string(20):intern(names) }, broadcast",
            "shooter", 20, 3000, shooter_map("names"), {"names": u(20)}, False, {"names": w})
        run("mmo names on enter, name = t.string(20):intern(names) in catch-up adds",
            "mmo", 20, 3000, mmo_map("names"), {"names": u(20)}, True, {"names": w})
        wi = math.ceil(math.log2(max(256, W)))
        run("tycoon: label, purchase item, notify { item, level } with item t.string(32):intern(items); chat inline",
            "tycoon", 10, 3000, tycoon_map("items"), {"items": u(32)}, True, {"items": wi})
    print()
    for W in (64, 4096):
        column_ids("mmo", 20, W)
