import sys, random, struct
sys.path.insert(0, "pylib")
import zstandard as zs
random.seed(2)
items = ["Sword_of_Flames","Health_Potion","Mana_Potion","Iron_Shield","Golden_Apple","Wooden_Bow","Arrow","Dragon_Scale","Ancient_Rune","Teleport_Scroll"] + [f"Item_{i:03d}" for i in range(60)]
w = [1/(i+1) for i in range(len(items))]
def frame():
    out_s = bytearray(); out_i = bytearray()
    for _ in range(random.randint(5, 25)):
        kind = random.choice([0,1,2])
        if kind == 0:  # inventory add: (u8 evt, string item, u16 count)
            it = random.choices(range(len(items)), w)[0]; s = items[it].encode()
            out_s += bytes([0, len(s)]) + s + struct.pack('<H', random.randint(1,5))
            out_i += bytes([0, it]) + struct.pack('<H', random.randint(1,5))
        elif kind == 1:  # damage: u8 evt, u16 target, u8 amount
            b = bytes([1]) + struct.pack('<HB', random.randrange(1000), random.randrange(100))
            out_s += b; out_i += b
        else:  # sound: u8 evt, string name
            it = random.choices(range(10), w[:10])[0]; s = ("sfx/" + items[it]).encode()
            out_s += bytes([2, len(s)]) + s; out_i += bytes([2, it])
    return bytes(out_s), bytes(out_i)
F = [frame() for _ in range(500)]
for name, idx in (("strings inline", 0), ("interned ids (static table)", 1)):
    fs = [f[idx] for f in F]
    raw = sum(map(len, fs))/len(fs)
    z = zs.ZstdCompressor(level=3)
    zz_ = sum(len(z.compress(f)) for f in fs)/len(fs)
    d = zs.train_dictionary(2048, fs[:300]); zd = zs.ZstdCompressor(level=3, dict_data=d)
    zdd = sum(len(zd.compress(f)) for f in fs[300:])/200
    print(f"{name:30s} raw {raw:6.0f}  zstd3 {zz_:6.0f}  zstd3+dict {zdd:6.0f}")
