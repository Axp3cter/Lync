"""Claim 2 (bytes): what masking costs on the wire after engine compression, for v5-shaped frames.

v5 frame = bit section (column coder, incompressible) + byte tail (strings). This reuses the compression study's
traffic models and its col_bits_pred layout as the bit section and inline strings as the tail
(probes/compression/sim_mixed.py), and the engine model of probes/compression/wire.py (raw under 100 B; zstd
with or without raw fallback). Masking XORs a keystream (any PRF output is uniform, so os.urandom stands in).

Cases per frame: plain; mask the bit section only; mask the tail only; mask both.
Also the draft-wire synthetic frames of probes/client-security/zmask.py, for comparison with its +62-272%.

Usage: python3 -I mask_bytes.py <dir holding zstandard> <repo>/.data/docs/probes/compression
"""
import os, sys

sys.path.insert(0, sys.argv[1])
sys.path.insert(0, sys.argv[2])
import traffic  # noqa: E402
from layouts import Layout  # noqa: E402
from wire import engine_len, leb128, zstd_len  # noqa: E402


def mask(b: bytes) -> bytes:
    k = os.urandom(len(b))
    return bytes(x ^ y for x, y in zip(b, k))


def strings_section(f):
    out = bytearray()
    for _, s in f.strings:
        e = s.encode()
        leb128(len(e), out)
        out += e
    return bytes(out)


def run(level, fallback):
    print(f"\n== engine model: zstd level {level}, threshold 100 B, raw fallback {fallback}")
    print(f"{'model':9} {'frames':>6} {'bits B':>7} {'tail B':>7} | {'plain':>7} {'mask bits':>10} {'mask tail':>10} {'mask all':>10}")
    for model, kw in (("tycoon", dict(hz=10)), ("shooter", dict(hz=20)), ("shooter", dict(hz=60)), ("mmo", dict(hz=20))):
        m = traffic.MODELS[model](seed=61, **kw)
        fr = [m.step() for _ in range(600)]
        lay = Layout(m)
        tot = [0, 0, 0, 0]
        nb = nt = n = 0
        for i in range(3, len(fr)):
            st = lay.col_bits_pred(fr, i, 1)
            s = strings_section(fr[i])
            cases = (st + s, mask(st) + s, st + mask(s), mask(st) + mask(s))
            for j, c in enumerate(cases):
                tot[j] += engine_len(c, level=level, fallback=fallback)
            nb += len(st); nt += len(s); n += 1
        p = tot[0] / n
        cells = [f"{t / n:7.1f}" if j == 0 else f"{t / n:6.1f} {100 * (t / n / p - 1):+4.0f}%" for j, t in enumerate(tot)]
        print(f"{model + str(kw['hz']):9} {n:6d} {nb / n:7.1f} {nt / n:7.1f} | " + " ".join(f"{c:>10}" for c in cells))


for level in (1, 3):
    for fb in (True, False):
        run(level, fb)

# large tails: catch-up of 500 names, a 600 B text sample, and a 4000 B chat log, behind one shooter60 bit section
print("\n== large tails behind one shooter60 bit section (zstd 3, fallback)")
_m = traffic.MODELS["shooter"](seed=3, hz=60)
_fr = [_m.step() for _ in range(41)]
bits = Layout(_m).col_bits_pred(_fr, 40, 1)
names = b"".join(bytes([len(x)]) + x.encode() for x in traffic.NAMES * 10)[:4000]
text = (" ".join(traffic.ITEMS[:40]) + " " + " ".join(traffic.NAMES)).encode()[:600]
for label, tail in (("item/player text", text), ("player names", names)):
    plain = engine_len(bits + tail)
    mt = engine_len(bits + mask(tail))
    mb = engine_len(mask(bits) + tail)
    print(f"{label:18} bits {len(bits):3d} B tail {len(tail):4d} B raw {len(bits) + len(tail):5d} plain {plain:5d}  mask bits {mb:5d} ({100 * (mb / plain - 1):+.1f}%)  mask tail {mt:5d} ({100 * (mt / plain - 1):+.1f}%)")

# draft-wire synthetic frames (zmask.py's generator), engine model with and without fallback
print("\n== zmask.py's synthetic draft-wire frames, masked whole (zstd 3)")
import random, struct  # noqa: E402
rng = random.Random(1)


def frame(kind, n):
    b = bytearray()
    if kind == "inputs":
        x, y, z = 30000, 2000, 30000
        while len(b) < n:
            x += rng.randint(-40, 40); z += rng.randint(-40, 40)
            b += bytes([7]) + struct.pack("<HHH", x & 0xffff, y, z & 0xffff) + bytes([rng.choice([0, 0, 0, 1])])
    else:
        words = [b"hello", b"trade", b"sword", b"shield", b"team", b"red", b"blue", b"ok"]
        while len(b) < n:
            w = b" ".join(rng.choice(words) for _ in range(rng.randint(2, 6)))
            b += bytes([3, len(w)]) + w
    return bytes(b[:n])


for kind in ("inputs", "chatlike"):
    for n in (256, 1024, 4096):
        f = frame(kind, n)
        pz, mz = zstd_len(f, 3), zstd_len(mask(f), 3)
        pe, me = engine_len(f), engine_len(mask(f))
        print(f"{kind:9} {n:5d}: zstd-only plain {pz:5d} masked {mz:5d} ({100 * (mz / pz - 1):+.0f}%) | with fallback plain {pe:5d} masked {me:5d} ({100 * (me / pe - 1):+.0f}%)")
