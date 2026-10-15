"""Diffusion check of HalfSipHash under altered rotation amounts (U2).

For a rotation set and round counts (c, d), flips every bit of a random 16-byte message under a
random key and records which of the 32 output bits change. Reports the worst |P(flip) - 0.5| over
all (input bit, output bit) pairs. Ideal is 0; with S samples the noise floor is about
4 * 0.5 / sqrt(S) at the maximum over 128 x 32 pairs. A necessary condition, not a proof of PRF
quality.

Usage: python3 -I avalanche.py [samples] [random_sets] [seed]
"""
import random
import sys

M = 0xFFFFFFFF
REFERENCE = (5, 16, 8, 7, 13, 16)


def rotl(x, b):
    b %= 32
    return ((x << b) | (x >> (32 - b))) & M if b else x


def rnd(v, r):
    v0, v1, v2, v3 = v
    v0 = (v0 + v1) & M; v1 = rotl(v1, r[0]) ^ v0; v0 = rotl(v0, r[1])
    v2 = (v2 + v3) & M; v3 = rotl(v3, r[2]) ^ v2
    v0 = (v0 + v3) & M; v3 = rotl(v3, r[3]) ^ v0
    v2 = (v2 + v1) & M; v1 = rotl(v1, r[4]) ^ v2; v2 = rotl(v2, r[5])
    return [v0, v1, v2, v3]


def hsh(k0, k1, msg, c, d, r, iv=(0x6C796765, 0x74656462)):
    v = [k0, k1, iv[0] ^ k0, iv[1] ^ k1]
    n = len(msg)
    stop = n - n % 4
    for at in range(0, stop, 4):
        m = int.from_bytes(msg[at:at + 4], "little")
        v[3] ^= m
        for _ in range(c):
            v = rnd(v, r)
        v[0] ^= m
    last = (n & 0xFF) << 24
    for i, byte in enumerate(msg[stop:]):
        last |= byte << (8 * i)
    v[3] ^= last
    for _ in range(c):
        v = rnd(v, r)
    v[0] ^= last
    v[2] ^= 0xFF
    for _ in range(d):
        v = rnd(v, r)
    return v[1] ^ v[3]


def worst_bias(r, c, d, samples, rng, length=16):
    counts = [[0] * 32 for _ in range(length * 8)]
    for _ in range(samples):
        k0, k1 = rng.getrandbits(32), rng.getrandbits(32)
        msg = bytearray(rng.getrandbits(8) for _ in range(length))
        base = hsh(k0, k1, msg, c, d, r)
        for bit in range(length * 8):
            msg[bit // 8] ^= 1 << (bit % 8)
            diff = base ^ hsh(k0, k1, msg, c, d, r)
            msg[bit // 8] ^= 1 << (bit % 8)
            row = counts[bit]
            for o in range(32):
                if diff >> o & 1:
                    row[o] += 1
    return max(abs(x / samples - 0.5) for row in counts for x in row)


def main():
    samples = int(sys.argv[1]) if len(sys.argv) > 1 else 400
    sets = int(sys.argv[2]) if len(sys.argv) > 2 else 40
    rng = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 1)
    # reference vector: HalfSipHash-2-4, 32-bit output, key 00..07, empty message -> a9 35 9f 5b
    k = bytes(range(8))
    got = hsh(int.from_bytes(k[:4], "little"), int.from_bytes(k[4:], "little"), b"", 2, 4, REFERENCE)
    print("reference vector 2-4 empty:", got.to_bytes(4, "little").hex(), "(expected a9359f5b)")
    print(f"samples {samples}; noise floor about {4 * 0.5 / samples ** 0.5:.3f}")
    named = {
        "reference": REFERENCE,
        "altered (6,16,9,11,13,16)": (6, 16, 9, 11, 13, 16),
        "all zero": (0, 0, 0, 0, 0, 0),
        "multiples of 8": (8, 16, 8, 8, 16, 16),
        "all 16": (16, 16, 16, 16, 16, 16),
    }
    for c, d in [(1, 3), (2, 4)]:
        for name, r in named.items():
            print(f"{c}-{d} {name:28s} worst bias {worst_bias(r, c, d, samples, rng):.3f}")
    # random sets with every amount in 1..31, drawn as a build would draw them
    for c, d in [(1, 3), (2, 4)]:
        biases = []
        for _ in range(sets):
            r = tuple(rng.randint(1, 31) for _ in range(6))
            biases.append((worst_bias(r, c, d, samples, rng), r))
        biases.sort()
        bad = [b for b in biases if b[0] > 0.15]
        print(f"{c}-{d} random sets: {sets}; worst bias min {biases[0][0]:.3f} median "
              f"{biases[len(biases) // 2][0]:.3f} max {biases[-1][0]:.3f}; above 0.15: {len(bad)}")
        for b, r in biases[-3:]:
            print(f"    {r} {b:.3f}")


main()
