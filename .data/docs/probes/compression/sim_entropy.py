"""Q6: what does entropy coding with offline-trained tables add over (a) engine zstd
on byte-aligned frames and (b) the bit-packed column coder (col_bits_pred)?

Coders, all with tables trained on a different-seed run of the same model:
  byteHuff     Quake 3 style: static Huffman over the bytes of a byte-aligned frame
               (layout dlt_col_varint), one table per model (msg_hData analogue).
  bucketHuff   per-field static Huffman over 16 Unity-style buckets of the zigzag
               residual, raw offset bits after the code (Unity Netcode's model, but
               trained per field instead of the fixed default).
  bucketANS    same buckets, ideal static rANS cost (-log2 p) + 4 bytes final state.
  symANS       per-field static rANS over a direct alphabet 0..62 plus escape (EG-0 of the
               excess), ideal cost + 4 bytes.
  ctxANS       symANS with 4 contexts per field: magnitude class of the previous field's
               residual in the same row (captures x/z correlation when turning).
  adaptAC      adaptive arithmetic coding of the buckets, counts initialised from the
               trained table (weight 16) and updated per symbol; ideal cost + 4 bytes.
Column headers (mode bits) are charged the same as col_bits_pred for bucket coders.

Usage: PYTHONPATH=<zstandard dir> python3 sim_entropy.py
"""
import heapq
import math
from collections import Counter

import traffic
from layouts import Layout
from wire import zz, engine_len, UNITY_BUCKET_OFFSETS, UNITY_BUCKET_SIZES

CASES = [("shooter60", "shooter", dict(hz=60), 1), ("racing60", "racing", dict(hz=60), 1),
         ("mmo20", "mmo", dict(hz=20), 1), ("shooter100p20", "shooter", dict(hz=20, players=100), 1),
         ("shooter60-unrel", "shooter", dict(hz=60), 6)]
N = 300


def bucket(v):
    b = 15
    while UNITY_BUCKET_OFFSETS[b] > v:
        b -= 1
    return b


def huffman_lengths(freq):
    """Code lengths for symbols with freq>0 (others get a length via +1 smoothing)."""
    items = [(f, i, None) for i, f in enumerate(freq)]
    heap = [(f, i, (i,)) for i, f in enumerate(freq)]
    heapq.heapify(heap)
    depth = [0] * len(freq)
    cnt = len(freq)
    while len(heap) > 1:
        f1, _, s1 = heapq.heappop(heap)
        f2, _, s2 = heapq.heappop(heap)
        for s in s1 + s2:
            depth[s] += 1
        heapq.heappush(heap, (f1 + f2, cnt, s1 + s2))
        cnt += 1
    return depth


def residual_columns(lay, frames, idx, age):
    f, base = frames[idx], frames[idx - age]
    ids = [i for i in sorted(f.rows) if i in base.rows]
    p = lay.predict(frames, idx, age)
    ds = lay.deltas(f, base, ids, p)
    return [[zz(d[k]) for d in ds] for k in range(lay.nf)]


def ctx_of(cols, k, j):
    """Context for field k of row j: magnitude class of field k-1's residual in row j."""
    if k == 0:
        return 0
    v = cols[k - 1][j]
    return 0 if v == 0 else 1 if v < 4 else 2 if v < 32 else 3


def main():
    print(f"{'case':16s} {'colbits':>8s} {'bucketHuff':>10s} {'bucketANS':>9s} {'adaptAC':>8s} {'symANS':>7s} {'ctxANS':>7s} "
          f"{'bytes':>6s} {'+zstd3':>7s} {'byteHuff':>8s} {'bHuff+z':>8s}   (mean bytes/frame)")
    for label, model, kw, age in CASES:
        m = traffic.MODELS[model](seed=11, **kw)
        frames = [m.step() for _ in range(N)]
        tm = traffic.MODELS[model](seed=99, **kw)
        train = [tm.step() for _ in range(N)]
        lay = Layout(m)
        # ---- train per-field bucket tables and the byte table -------------
        bfreq = [[1] * 16 for _ in range(lay.nf)]
        byfreq = [1] * 256
        for i in range(3 * age, N):
            cols = residual_columns(lay, train, i, age)
            for k, col in enumerate(cols):
                for v in col:
                    bfreq[k][bucket(v)] += 1
            for by in lay.dlt_col_varint(train, i, age):
                byfreq[by] += 1
        blen = [huffman_lengths(fr) for fr in bfreq]
        bylen = huffman_lengths(byfreq)
        bprob = [[c / sum(fr) for c in fr] for fr in bfreq]
        sfreq = [[[0.1] * 64 for _ in range(4)] for _ in range(lay.nf)]
        for i in range(3 * age, N):
            cols = residual_columns(lay, train, i, age)
            for k, col in enumerate(cols):
                for j, v in enumerate(col):
                    c = ctx_of(cols, k, j)
                    sfreq[k][c][min(v, 63)] += 1
        sprob0 = []
        for k in range(lay.nf):
            merged = [sum(sfreq[k][c][s] for c in range(4)) for s in range(64)]
            t = sum(merged)
            sprob0.append([x / t for x in merged])
        sprobc = [[[x / sum(sfreq[k][c]) for x in sfreq[k][c]] for c in range(4)] for k in range(lay.nf)]
        tot = Counter()
        n = 0
        for i in range(3 * age, N):
            n += 1
            colbits = lay.col_bits_pred(frames, i, age)
            tot["colbits"] += len(colbits)
            # non-column overhead in col_bits_pred: set changes + events + headers.
            cols = residual_columns(lay, frames, i, age)
            pure = 0
            for k, col in enumerate(cols):
                if lay.kinds[k] == "b":
                    pure += len(col)
                    continue
                # cost of this column inside col_bits_pred is not separable; recompute
                # its best mode cost the same way the layout does
                def egb(v, kk):
                    return 2 * ((v + (1 << kk)).bit_length()) - 1 - kk
                if not any(col):
                    pure += 2
                    continue
                best = min(sum(egb(v, kk) for v in col) for kk in range(16)) + 6
                nz = [(j, v) for j, v in enumerate(col) if v]
                for kk in range(16):
                    c2, last = 0, -1
                    for j, v in nz:
                        c2 += egb(j - last - 1, 0) + egb(v - 1, kk)
                        last = j
                    best = min(best, c2 + egb(len(nz), 0) + 6)
                best = min(best, len(col) * lay.bits[k] + 2)
                pure += best
            overhead_bits = 8 * len(colbits) - pure
            hb = ab = ac = sb = cb = overhead_bits
            for k, col in enumerate(cols):
                if lay.kinds[k] == "b":
                    hb += len(col)
                    ab += len(col)
                    ac += len(col)
                    sb += len(col)
                    cb += len(col)
                    continue
                if not any(col):
                    hb += 2
                    ab += 2
                    ac += 2
                    sb += 2
                    cb += 2
                    continue
                hb += 2
                ab += 2
                ac += 2
                sb += 2
                cb += 2
                for j, v in enumerate(col):
                    esc = 0 if v < 63 else 2 * ((v - 63 + 1).bit_length()) - 1
                    sb += -math.log2(sprob0[k][min(v, 63)]) + esc
                    cb += -math.log2(sprobc[k][ctx_of(cols, k, j)][min(v, 63)]) + esc
                cnt = [16 * p for p in bprob[k]]
                for v in col:
                    bk = bucket(v)
                    off = UNITY_BUCKET_SIZES[bk]
                    hb += blen[k][bk] + off
                    ab += -math.log2(bprob[k][bk]) + off
                    ac += -math.log2(cnt[bk] / sum(cnt)) + off
                    cnt[bk] += 1
            tot["bucketHuff"] += math.ceil(hb / 8)
            tot["bucketANS"] += math.ceil(ab / 8) + 4
            tot["adaptAC"] += math.ceil(ac / 8) + 4
            tot["symANS"] += math.ceil(sb / 8) + 4
            tot["ctxANS"] += math.ceil(cb / 8) + 4
            by = lay.dlt_col_varint(frames, i, age)
            tot["bytes"] += len(by)
            tot["bytes+z"] += engine_len(by, 3)
            hbits = sum(bylen[x] for x in by)
            tot["byteHuff"] += math.ceil(hbits / 8)
            tot["byteHuff+z"] += min(math.ceil(hbits / 8), engine_len(by, 3))
        print(f"{label:16s} {tot['colbits']/n:8.1f} {tot['bucketHuff']/n:10.1f} {tot['bucketANS']/n:9.1f} "
              f"{tot['adaptAC']/n:8.1f} {tot['symANS']/n:7.1f} {tot['ctxANS']/n:7.1f} {tot['bytes']/n:6.1f} {tot['bytes+z']/n:7.1f} {tot['byteHuff']/n:8.1f} "
              f"{tot['byteHuff+z']/n:8.1f}")


if __name__ == "__main__":
    main()
