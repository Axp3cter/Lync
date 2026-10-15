"""Round-level diffusion of the HalfSipHash permutation under altered rotation amounts (U2).

For a rotation set, applies r SipRounds to a random 128-bit state and to the same state with one
bit flipped, for every one of the 128 bits, over S samples. Reports:
  full   - the fewest rounds after which every input bit has changed every output bit at least once;
  b2, b3 - the worst |P(flip) - 0.5| over all 128 x 128 (input, output) pairs after 2 and 3 rounds.
A set that needs more rounds than the reference to diffuse makes 1-3 weaker; the test is necessary,
not sufficient, for PRF quality.

Usage: python3 -I diffusion.py [samples] [random_sets] [seed]
"""
import random
import sys

M = 0xFFFFFFFF
REFERENCE = (5, 16, 8, 7, 13, 16)


def rotl(x, b):
    return ((x << b) | (x >> (32 - b))) & M if b % 32 else x


def rnd(v0, v1, v2, v3, r):
    v0 = (v0 + v1) & M; v1 = rotl(v1, r[0]) ^ v0; v0 = rotl(v0, r[1])
    v2 = (v2 + v3) & M; v3 = rotl(v3, r[2]) ^ v2
    v0 = (v0 + v3) & M; v3 = rotl(v3, r[3]) ^ v0
    v2 = (v2 + v1) & M; v1 = rotl(v1, r[4]) ^ v2; v2 = rotl(v2, r[5])
    return v0, v1, v2, v3


def run(state, rounds, r):
    out = []
    for _ in range(rounds):
        state = rnd(*state, r)
        out.append(state)
    return out


def pack(s):
    return s[0] | s[1] << 32 | s[2] << 64 | s[3] << 96


def measure(r, samples, rng, max_rounds=4):
    reach = [[0] * 128 for _ in range(max_rounds)]  # per round: OR of output diffs per input bit
    counts = {2: [[0] * 128 for _ in range(128)], 3: [[0] * 128 for _ in range(128)]}
    for _ in range(samples):
        s = tuple(rng.getrandbits(32) for _ in range(4))
        base = [pack(x) for x in run(s, max_rounds, r)]
        for bit in range(128):
            t = list(s)
            t[bit // 32] ^= 1 << (bit % 32)
            flipped = [pack(x) for x in run(tuple(t), max_rounds, r)]
            for k in range(max_rounds):
                reach[k][bit] |= base[k] ^ flipped[k]
            for k in (2, 3):
                diff = base[k - 1] ^ flipped[k - 1]
                row = counts[k][bit]
                while diff:
                    low = diff & -diff
                    row[low.bit_length() - 1] += 1
                    diff ^= low
    full = next((k + 1 for k in range(max_rounds) if all(x == (1 << 128) - 1 for x in reach[k])), None)
    bias = {k: max(abs(x / samples - 0.5) for row in counts[k] for x in row) for k in (2, 3)}
    return full, bias[2], bias[3]


def main():
    samples = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    sets = int(sys.argv[2]) if len(sys.argv) > 2 else 40
    rng = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 1)
    print(f"samples {samples}; bias noise floor about {4.5 * 0.5 / samples ** 0.5:.3f}")
    named = {
        "reference": REFERENCE,
        "altered (6,16,9,11,13,16)": (6, 16, 9, 11, 13, 16),
        "multiples of 8": (8, 16, 8, 8, 16, 16),
        "all 16": (16, 16, 16, 16, 16, 16),
        "all 1": (1, 1, 1, 1, 1, 1),
    }
    for name, r in named.items():
        full, b2, b3 = measure(r, samples, rng)
        print(f"{name:28s} full {full} b2 {b2:.3f} b3 {b3:.3f}")
    rows = []
    for _ in range(sets):
        r = tuple(rng.randint(1, 31) for _ in range(6))
        rows.append((measure(r, samples, rng), r))
    ref = measure(REFERENCE, samples, rng)
    no_worse = [x for x in rows if x[0][0] is not None and x[0][0] <= ref[0] and x[0][2] <= ref[2] + 0.02]
    print(f"random sets {sets}: no worse than the reference (full <= {ref[0]}, b3 <= ref + 0.02): "
          f"{len(no_worse)}")
    fulls = {}
    for (full, _, _), _ in rows:
        fulls[full] = fulls.get(full, 0) + 1
    print("rounds to full dependency among random sets:", dict(sorted(fulls.items(), key=str)))
    for (full, b2, b3), r in sorted(rows, key=lambda x: -x[0][2])[:5]:
        print(f"    worst b3: {r} full {full} b2 {b2:.3f} b3 {b3:.3f}")


main()
