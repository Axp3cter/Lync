import sys, random, struct, hashlib
sys.path.insert(0, sys.argv[1])
import zstandard as zstd
C = zstd.ZstdCompressor(level=3)
rng = random.Random(1)
def keystream(key, n, nonce):
    out = b""; c = 0
    while len(out) < n:
        out += hashlib.blake2b(struct.pack("<QQ", nonce, c), key=key, digest_size=64).digest(); c += 1
    return out[:n]
def frame(kind, n):
    b = bytearray()
    if kind == "inputs":   # many small same-definition messages: id byte + 3x u16 quantized near-constant values + flags
        x, y, z = 30000, 2000, 30000
        while len(b) < n:
            x += rng.randint(-40, 40); z += rng.randint(-40, 40)
            b += bytes([7]) + struct.pack("<HHH", x & 0xffff, y, z & 0xffff) + bytes([rng.choice([0, 0, 0, 1])])
    elif kind == "chatlike": # strings
        words = [b"hello", b"trade", b"sword", b"shield", b"team", b"red", b"blue", b"ok"]
        while len(b) < n:
            w = b" ".join(rng.choice(words) for _ in range(rng.randint(2, 6)))
            b += bytes([3, len(w)]) + w
    elif kind == "random":
        b = bytearray(rng.getrandbits(8) for _ in range(n))
    return bytes(b[:n])
key = b"k" * 16
print(f"{'kind':9} {'size':>5} {'plain':>6} {'permid':>6} {'xorfix':>6} {'stream':>6}  (zstd-3 compressed bytes; raw size for reference)")
for kind in ["inputs", "chatlike", "random"]:
    for n in [16, 64, 256, 1024, 4096]:
        f = frame(kind, n)
        perm = bytes(((v * 167 + 13) & 0xff) if i % 8 == 0 else v for i, v in enumerate(f))  # relabel id bytes (bijection)
        fixmask = keystream(key, n, 0)                         # same mask every frame (per-session static XOR)
        xorfix = bytes(a ^ m for a, m in zip(f, fixmask))
        xors = bytes(a ^ m for a, m in zip(f, keystream(key, n, 12345)))  # per-frame keystream
        cs = [len(C.compress(x)) for x in (f, perm, xorfix, xors)]
        print(f"{kind:9} {n:5} " + " ".join(f"{c:6}" for c in cs))
