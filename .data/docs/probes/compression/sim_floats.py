"""Q4: floats and spatial values.

  1. step size of f32 / f16 / bf16 / fixed point at typical Roblox magnitudes
  2. lossless float coders (Gorilla, Chimp, 32-bit adaptations) vs quantise+predict+EG
     on the shooter's per-entity position series, and ALP's decimal test
  3. predictors (delta, linear, Unity's guarded linear, quadratic) at 20/30/60 Hz and
     at baseline ages of 1 frame and ~100 ms; residual size in EG-k bits
  4. rotation and direction error tables (Monte Carlo): smallest-three, naive 4x,
     octahedral, yaw-only, axis-aligned

Usage: PYTHONPATH=<zstandard dir> python3 sim_floats.py
"""
import math
import random
import struct

import traffic
from layouts import Layout, wrap
from wire import zz


def f32(v):
    return struct.unpack("<f", struct.pack("<f", v))[0]


def f32bits(v):
    return struct.unpack("<I", struct.pack("<f", v))[0]


def ulp_f16(v):
    e = math.floor(math.log2(abs(v)))
    return 2.0 ** (e - 10)


def ulp_bf16(v):
    e = math.floor(math.log2(abs(v)))
    return 2.0 ** (e - 7)


def ulp_f32(v):
    e = math.floor(math.log2(abs(v)))
    return 2.0 ** (e - 23)


def part1():
    print("1. step size (studs) at magnitude; max error is half the step")
    print(f"{'magnitude':>10s} {'f32':>12s} {'f16':>10s} {'bf16':>10s}")
    for v in (1, 10, 100, 1000, 4000, 10000, 60000):
        print(f"{v:10d} {ulp_f32(v):12.2e} {ulp_f16(v) if v < 65504 else float('inf'):10.4f} {ulp_bf16(v):10.3f}")
    print("fixed point: bits = ceil(log2(range/step)); e.g. +-1024 studs at 1/32 = 16 bits, "
          "+-4096 at 1/64 = 19 bits, +-16384 at 1/16 = 19 bits")


def gorilla_bits(series):
    """Gorilla XOR coding adapted to float32 (5-bit leading count, 5-bit length)."""
    bits = 32
    prev = f32bits(series[0])
    pl, pt = None, None
    for v in series[1:]:
        cur = f32bits(v)
        x = cur ^ prev
        prev = cur
        if x == 0:
            bits += 1
            continue
        lead = 32 - x.bit_length()
        trail = (x & -x).bit_length() - 1
        if pl is not None and lead >= pl and trail >= pt:
            bits += 2 + (32 - pl - pt)
        else:
            bits += 2 + 5 + 5 + (32 - lead - trail)
            pl, pt = lead, trail
    return bits


def chimp_bits(series):
    """Chimp (Liakos et al. VLDB 2022) adapted to float32: leading zeros rounded to
    {0,4,6,8,10,12,14,16} (3 bits), trailing-zero threshold 4."""
    rounds = [0, 4, 6, 8, 10, 12, 14, 16]

    def rl(lead):
        return max(r for r in rounds if r <= lead)

    bits = 32
    prev = f32bits(series[0])
    plead = None
    for v in series[1:]:
        cur = f32bits(v)
        x = cur ^ prev
        prev = cur
        if x == 0:
            bits += 2
            continue
        lead = rl(32 - x.bit_length())
        trail = (x & -x).bit_length() - 1
        if trail > 4:
            bits += 2 + 3 + 5 + (32 - lead - trail)
            plead = None
        elif lead == plead:
            bits += 2 + (32 - lead)
        else:
            bits += 2 + 3 + (32 - lead)
            plead = lead
    return bits


def alp_cost(values, max_e=9):
    """ALP's premise: v == f32(round(v*10^e) / 10^e) for a small exponent e; the integers
    are then frame-of-reference bit-packed per vector. Returns (median e, bits/value)
    for vectors of 1024 values, with the per-vector e chosen as the most common minimal e.
    Values that fail every e count as 32-bit exceptions plus 16 bits of position."""
    import statistics
    es = []
    for v in values:
        for e in range(max_e + 1):
            d = round(v * 10 ** e)
            if f32(d / 10 ** e) == v:
                es.append(e)
                break
        else:
            es.append(None)
    total = 0
    for j in range(0, len(values), 1024):
        vec = values[j:j + 1024]
        ve = [e for e in es[j:j + 1024] if e is not None]
        e = statistics.mode(ve) if ve else 0
        ds, exc = [], 0
        for v in vec:
            d = round(v * 10 ** e)
            if f32(d / 10 ** e) == v:
                ds.append(d)
            else:
                exc += 1
        width = (max(ds) - min(ds)).bit_length() if ds else 0
        total += len(ds) * width + exc * 48 + 64
    ok = [e for e in es if e is not None]
    return statistics.median(ok) if ok else None, total / len(values)


def eg_bits(v, k):
    return 2 * ((v + (1 << k)).bit_length()) - 1 - k


def part2():
    print("\n2. lossless float coders vs quantise + predict + EG (shooter, x/y/z per entity over time)")
    for hz in (60, 20):
        m = traffic.Shooter(hz=hz, seed=31)
        fr = [m.step() for _ in range(600 if hz == 60 else 200)]
        series = {}
        for f in fr:
            for eid, fl in f.floats.items():
                for c in range(3):
                    series.setdefault((eid, c), []).append(f32(fl[c]))
        nvals = sum(len(s) for s in series.values())
        g = sum(gorilla_bits(s) for s in series.values()) / nvals
        c = sum(chimp_bits(s) for s in series.values()) / nvals
        allv = [v for s in series.values() for v in s]
        alp_e, alp_b = alp_cost(allv[:8192])
        lay = Layout(m)
        res = []
        for i in range(3, len(fr)):
            p = lay.predict(fr, i, 1)
            for eid, row in fr[i].rows.items():
                for k in range(3):
                    res.append(zz(wrap(row[k] - p[eid][k], 16)))
        kbest = min(range(12), key=lambda k: sum(eg_bits(v, k) for v in res))
        q = sum(eg_bits(v, kbest) for v in res) / len(res)
        print(f"  {hz:2d} Hz: Gorilla {g:5.1f} b/val, Chimp {c:5.1f} b/val, ALP {alp_b:5.1f} b/val (median exponent {alp_e}); "
              f"1/32-stud quantised + guarded linear prediction + EG-{kbest}: {q:4.2f} b/val")


def part3():
    print("\n3. predictors: mean EG bits per position component (best k), by rate and baseline age")
    print(f"  {'model':10s} {'Hz':>3s} {'age':>4s} {'delta':>6s} {'linear':>7s} {'guarded':>8s} {'quad':>6s}")
    for name, hz, ages in (("shooter", 60, (1, 6)), ("shooter", 30, (1, 3)), ("shooter", 20, (1, 2)),
                           ("racing", 60, (1, 6)), ("mmo", 20, (1, 2))):
        m = traffic.MODELS[name](hz=hz, seed=41)
        fr = [m.step() for _ in range(360)]
        bits = [m.schema[k][2] for k in range(3)]
        for age in ages:
            acc = {"delta": [], "linear": [], "guarded": [], "quad": []}
            for i in range(3 * age, len(fr)):
                f = fr[i]
                b0, b1, b2 = fr[i - age], fr[i - 2 * age], fr[i - 3 * age]
                for eid, row in f.rows.items():
                    if eid not in b0.rows or eid not in b1.rows or eid not in b2.rows:
                        continue
                    for k in range(3):
                        B = bits[k]
                        r0, r1, r2 = b0.rows[eid][k], b1.rows[eid][k], b2.rows[eid][k]
                        d01 = wrap(r0 - r1, B)
                        d12 = wrap(r1 - r2, B)
                        acc["delta"].append(zz(wrap(row[k] - r0, B)))
                        acc["linear"].append(zz(wrap(row[k] - (r0 + d01), B)))
                        guarded = r0 if abs(wrap(r0 - (r1 + d12), B)) >= abs(d01) else r0 + d01
                        acc["guarded"].append(zz(wrap(row[k] - guarded, B)))
                        acc["quad"].append(zz(wrap(row[k] - (r0 + d01 + (d01 - d12)), B)))
            out = []
            for key in ("delta", "linear", "guarded", "quad"):
                vals = acc[key]
                kb = min(range(16), key=lambda kk: sum(eg_bits(v, kk) for v in vals))
                out.append(sum(eg_bits(v, kb) for v in vals) / len(vals))
            print(f"  {name:10s} {hz:3d} {age:4d} " + " ".join(f"{x:6.2f}" for x in out[:1]) +
                  f" {out[1]:7.2f} {out[2]:8.2f} {out[3]:6.2f}")


def rand_quat(r):
    u1, u2, u3 = r.random(), r.random(), r.random()
    return (math.sqrt(1 - u1) * math.sin(2 * math.pi * u2), math.sqrt(1 - u1) * math.cos(2 * math.pi * u2),
            math.sqrt(u1) * math.sin(2 * math.pi * u3), math.sqrt(u1) * math.cos(2 * math.pi * u3))


def quat_angle(a, b):
    d = abs(sum(x * y for x, y in zip(a, b)))
    return math.degrees(2 * math.acos(min(1.0, d)))


def s3_roundtrip(q, b):
    idx = max(range(4), key=lambda i: abs(q[i]))
    s = -1 if q[idx] < 0 else 1
    lim = 1 / math.sqrt(2)
    steps = (1 << b) - 1
    rest = []
    for i in range(4):
        if i == idx:
            continue
        v = q[i] * s
        qv = round((v + lim) / (2 * lim) * steps)
        rest.append(qv / steps * 2 * lim - lim)
    big = math.sqrt(max(0.0, 1 - sum(x * x for x in rest)))
    out = rest[:idx] + [big] + rest[idx:]
    n = math.sqrt(sum(x * x for x in out))
    return tuple(x / n for x in out)


def naive4_roundtrip(q, b):
    steps = (1 << b) - 1
    out = [round((x + 1) / 2 * steps) / steps * 2 - 1 for x in q]
    n = math.sqrt(sum(x * x for x in out))
    return tuple(x / n for x in out)


def oct_roundtrip(v, b):
    x, y, z = v
    s = abs(x) + abs(y) + abs(z)
    x, y, z = x / s, y / s, z / s
    if z < 0:
        x, y = (1 - abs(y)) * (1 if x >= 0 else -1), (1 - abs(x)) * (1 if y >= 0 else -1)
    steps = (1 << b) - 1
    qx = round((x + 1) / 2 * steps) / steps * 2 - 1
    qy = round((y + 1) / 2 * steps) / steps * 2 - 1
    qz = 1 - abs(qx) - abs(qy)
    if qz < 0:
        qx, qy = (1 - abs(qy)) * (1 if qx >= 0 else -1), (1 - abs(qx)) * (1 if qy >= 0 else -1)
    n = math.sqrt(qx * qx + qy * qy + qz * qz)
    return qx / n, qy / n, qz / n


def part4():
    r = random.Random(5)
    qs = [rand_quat(r) for _ in range(20000)]
    print("\n4a. rotations: angular error in degrees (max / mean over 20k random rotations)")
    print(f"  {'scheme':28s} {'bits':>5s} {'max':>7s} {'mean':>7s}")
    for b in (7, 8, 9, 10, 11, 12, 15):
        errs = [quat_angle(q, s3_roundtrip(q, b)) for q in qs]
        print(f"  {'smallest-three ' + str(b) + ' b/comp':28s} {2 + 3 * b:5d} {max(errs):7.3f} {sum(errs) / len(errs):7.3f}")
    for b in (8, 10):
        errs = [quat_angle(q, naive4_roundtrip(q, b)) for q in qs]
        print(f"  {'naive 4 x ' + str(b) + ' bits':28s} {4 * b:5d} {max(errs):7.3f} {sum(errs) / len(errs):7.3f}")
    for b in (8, 10, 12, 16):
        print(f"  {'yaw only ' + str(b) + ' bits':28s} {b:5d} {180 / (1 << b):7.3f} {90 / (1 << b):7.3f}")
    print(f"  {'axis-aligned (24 rotations)':28s} {5:5d} {0:7.3f} {0:7.3f}")
    print("\n4b. directions (octahedral): angular error in degrees (max / mean over 20k)")
    vs = []
    for _ in range(20000):
        z = r.uniform(-1, 1)
        a = r.uniform(0, 2 * math.pi)
        s = math.sqrt(1 - z * z)
        vs.append((s * math.cos(a), s * math.sin(a), z))
    for b in (8, 10, 12, 16):
        errs = []
        for v in vs:
            w = oct_roundtrip(v, b)
            d = max(-1.0, min(1.0, sum(x * y for x, y in zip(v, w))))
            errs.append(math.degrees(math.acos(d)))
        print(f"  {'oct ' + str(b) + ' b/axis':28s} {2 * b:5d} {max(errs):7.3f} {sum(errs) / len(errs):7.3f}")
    print("\n4c. Color3: 3 x u8 (Roblox's own Color3uint8) max error 0.5/255 = 0.20% per channel; "
          "RGB565 max error 1.6% (R,B) / 0.8% (G)")


if __name__ == "__main__":
    part1()
    part2()
    part3()
    part4()
