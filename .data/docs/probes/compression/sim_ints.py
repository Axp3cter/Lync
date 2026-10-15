"""Q3: integer codes compared on realistic value streams, raw and after engine zstd.

Streams (all non-negative after zigzag where signed):
  pos_pred60   shooter 60 Hz, x/y/z residual after guarded linear prediction
  pos_delta20  shooter 20 Hz, x/y/z delta vs previous frame
  mmo_delta20  MMO 20 Hz, all fields' deltas (mostly zero: idle NPCs)
  money_delta  tycoon value increments (multi-byte, skewed)
  money_abs    tycoon absolute values (large)
  id_gaps      MMO visible-set sorted id gaps
  str_len      string lengths from the string streams

Values are cut into per-frame chunks (the natural count per frame), each chunk is
encoded alone, and engine zstd (threshold 100, fallback, level 3) is applied to the
chunk alone, as it would be if that chunk were the whole frame. A second figure
pads chunks into ~600-byte frames (realistic large frame) to show zstd at its best.

Usage: PYTHONPATH=<zstandard dir> python3 sim_ints.py
"""
import math
from collections import Counter

import traffic
from layouts import Layout, wrap
from wire import (BitWriter, leb128, prefix_varint, sqlite4_varint, vu128, group_varint,
                  stream_vbyte, exp_golomb, elias_gamma, elias_delta, rice, rice_best_k,
                  class_code, unity_bucket, for_bitpack, pfor_bitpack, simple8b, zz,
                  engine_len)


def streams():
    out = {}
    # shooter 60 Hz positional residuals (prediction) ------------------------
    m = traffic.Shooter(hz=60, seed=21)
    fr = [m.step() for _ in range(400)]
    lay = Layout(m)
    chunks = []
    for i in range(3, len(fr)):
        p = lay.predict(fr, i, 1)
        c = []
        for eid, row in sorted(fr[i].rows.items()):
            for k in range(3):
                c.append(zz(wrap(row[k] - p[eid][k], 16)))
        chunks.append(c)
    out["pos_pred60"] = chunks
    m = traffic.Shooter(hz=20, seed=22)
    fr = [m.step() for _ in range(300)]
    chunks = []
    for i in range(1, len(fr)):
        c = []
        for eid, row in sorted(fr[i].rows.items()):
            for k in range(3):
                c.append(zz(wrap(row[k] - fr[i - 1].rows[eid][k], 16)))
        chunks.append(c)
    out["pos_delta20"] = chunks
    m = traffic.MMO(hz=20, seed=23)
    fr = [m.step() for _ in range(300)]
    chunks, gaps = [], []
    for i in range(1, len(fr)):
        c = []
        for eid, row in sorted(fr[i].rows.items()):
            b = fr[i - 1].rows.get(eid)
            if b is None:
                continue
            for k in range(len(row)):
                c.append(zz(wrap(row[k] - b[k], m.schema[k][2])))
        chunks.append(c)
        ids = sorted(fr[i].rows)
        gaps.append([ids[0]] + [ids[j] - ids[j - 1] - 1 for j in range(1, len(ids))])
    out["mmo_delta20"] = chunks
    out["id_gaps"] = gaps
    m = traffic.Tycoon(hz=10, seed=24)
    fr = [m.step() for _ in range(200)]
    dch, ach = [], []
    for i in range(1, len(fr)):
        d, a = [], []
        for eid, row in sorted(fr[i].rows.items()):
            a.append(row[2])
            b = fr[i - 1].rows.get(eid)
            if b is not None and row[2] != b[2]:
                d.append(row[2] - b[2])
        dch.append(d)
        ach.append(a)
    out["money_delta"] = dch
    out["money_abs"] = ach
    lens = []
    for name in ("tycoon", "mmo", "shooter"):
        mm = traffic.MODELS[name](seed=25)
        for _ in range(600):
            f = mm.step()
            lens += [len(s) for _, s in f.strings]
    out["str_len"] = [lens[j:j + 32] for j in range(0, len(lens), 32)]
    return out


def bits_codec(fn):
    def enc(vals):
        bw = BitWriter()
        fn(bw, vals)
        return bw.done()
    return enc


def eg_static(k):
    return bits_codec(lambda bw, vals: [exp_golomb(bw, v, k) for v in vals])


def eg_adaptive(bw, vals):
    best = min(range(16), key=lambda k: sum(2 * ((v + (1 << k)).bit_length()) - 1 - k for v in vals))
    bw.w(best, 4)
    for v in vals:
        exp_golomb(bw, v, best)


def rice_static(k):
    return bits_codec(lambda bw, vals: [rice(bw, v, k) for v in vals])


def rice_adaptive(bw, vals):
    k = rice_best_k(vals)
    bw.w(k, 5)
    for v in vals:
        rice(bw, v, k)


def bytes_codec(fn):
    def enc(vals):
        out = bytearray()
        for v in vals:
            fn(v, out)
        return bytes(out)
    return enc


def block_codec(fn):
    def enc(vals):
        out = bytearray()
        fn(vals, out)
        return bytes(out)
    return enc


def fixed_width(vals):
    w = max(1, (max(vals).bit_length() + 7) // 8) if vals else 1
    out = bytearray([w])
    for v in vals:
        out += v.to_bytes(w, "little")
    return bytes(out)


def main():
    S = streams()
    allvals = {k: [v for c in ch for v in c] for k, ch in S.items()}
    static_k_eg = {k: min(range(20), key=lambda kk: sum(2 * ((v + (1 << kk)).bit_length()) - 1 - kk for v in vals))
                   for k, vals in allvals.items()}
    static_k_rice = {k: rice_best_k(vals) for k, vals in allvals.items()}
    print("stream        values/chunk  mean   p50   p99   max     H0 bits/val  EG-k*  Rice-k*")
    for k, ch in S.items():
        vals = sorted(allvals[k])
        cnt = Counter(allvals[k])
        n = len(vals)
        h0 = -sum(c / n * math.log2(c / n) for c in cnt.values())
        print(f"{k:13s} {n/len(ch):10.1f} {sum(vals)/n:7.1f} {vals[n//2]:5d} {vals[int(n*.99)]:6d} {vals[-1]:9d} "
              f"{h0:8.2f} {static_k_eg[k]:6d} {static_k_rice[k]:6d}")
    codecs = {
        "fixed(width/chunk)": fixed_width,
        "LEB128": bytes_codec(leb128),
        "PrefixVarint": bytes_codec(prefix_varint),
        "SQLite4": bytes_codec(sqlite4_varint),
        "vu128": bytes_codec(vu128),
        "GroupVarint": block_codec(group_varint),
        "StreamVByte": block_codec(stream_vbyte),
        "EliasGamma": bits_codec(lambda bw, vals: [elias_gamma(bw, v) for v in vals]),
        "EliasDelta": bits_codec(lambda bw, vals: [elias_delta(bw, v) for v in vals]),
        "EG-k static": None,
        "EG-k per chunk": bits_codec(eg_adaptive),
        "Rice static": None,
        "Rice per chunk": bits_codec(rice_adaptive),
        "FOR(128)": block_codec(for_bitpack),
        "PFOR(128)": block_codec(pfor_bitpack),
        "Simple8b": block_codec(simple8b),
        "ClassCode(v5a)": bits_codec(lambda bw, vals: [class_code(bw, v) for v in vals]),
        "UnityBucket": bits_codec(lambda bw, vals: [unity_bucket(bw, v) for v in vals]),
    }
    print("\nbits per value: raw / after engine zstd-3 on the chunk alone / chunk inside a ~600 B frame")
    hdr = f"{'codec':20s}" + "".join(f"{k:>22s}" for k in S)
    print(hdr)
    for name, enc in codecs.items():
        line = f"{name:20s}"
        for k, ch in S.items():
            e = enc
            if name == "EG-k static":
                e = eg_static(static_k_eg[k])
            elif name == "Rice static":
                e = rice_static(static_k_rice[k])
            raw = eng = 0
            nv = 0
            big = bytearray()
            for c in ch:
                if not c:
                    continue
                b = e(c)
                raw += len(b)
                eng += engine_len(b, 3)
                nv += len(c)
                big += b
            # ~600 B frames made of consecutive chunks
            bigeng = 0
            for j in range(0, len(big), 600):
                bigeng += engine_len(bytes(big[j:j + 600]), 3)
            line += f"  {8*raw/nv:5.2f}/{8*eng/nv:5.2f}/{8*bigeng/nv:5.2f}"
        print(line)


if __name__ == "__main__":
    main()
