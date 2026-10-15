import sys, random, struct, math
sys.path.insert(0, "pylib")
import zstandard as zs
random.seed(1)
E = 60; T = 300
ents = [dict(id=random.randrange(1000), x=random.uniform(-500,500), y=random.uniform(0,50), z=random.uniform(-500,500),
             vx=random.uniform(-1,1), vz=random.uniform(-1,1), yaw=random.randrange(256), anim=random.randrange(4), hp=100) for _ in range(E)]
def q(v, lo, hi, bits): return max(0, min((1<<bits)-1, round((v-lo)/(hi-lo)*((1<<bits)-1))))
class BW:
    def __init__(s): s.acc=0; s.n=0; s.out=bytearray()
    def w(s, v, b):
        s.acc |= (v & ((1<<b)-1)) << s.n; s.n += b
        while s.n >= 8: s.out.append(s.acc & 255); s.acc >>= 8; s.n -= 8
    def done(s):
        if s.n: s.out.append(s.acc & 255)
        return bytes(s.out)
def zz(v): return (v<<1) ^ (v>>63)
def varint(v, out):
    while v >= 128: out.append((v&127)|128); v >>= 7
    out.append(v)
frames = {k: [] for k in ["aligned f32", "aligned q16", "bitpacked q", "delta aligned q (zigzag varint)", "delta bitpacked + dirty mask"]}
prev = None
for t in range(T):
    for e in ents:
        e['x'] += e['vx']; e['z'] += e['vz']
        if random.random() < 0.05: e['vx'] = random.uniform(-1,1); e['vz'] = random.uniform(-1,1)
        if random.random() < 0.1: e['yaw'] = (e['yaw'] + random.randint(-5,5)) % 256
        if random.random() < 0.02: e['anim'] = random.randrange(4)
        if random.random() < 0.01: e['hp'] = max(0, e['hp'] - random.randrange(30))
    cur = [(e['id'], q(e['x'],-1024,1024,16), q(e['y'],-64,192,12), q(e['z'],-1024,1024,16), e['yaw'], e['anim'], e['hp']) for e in ents]
    a = bytearray()
    for e in ents: a += struct.pack('<Hfffbbb', e['id'], e['x'], e['y'], e['z'], e['yaw']-128, e['anim'], e['hp'])
    frames["aligned f32"].append(bytes(a))
    b = bytearray()
    for c in cur: b += struct.pack('<HHHHBBB', *c)
    frames["aligned q16"].append(bytes(b))
    bw = BW()
    for c in cur:
        bw.w(c[0],10); bw.w(c[1],16); bw.w(c[2],12); bw.w(c[3],16); bw.w(c[4],8); bw.w(c[5],2); bw.w(c[6],7)
    frames["bitpacked q"].append(bw.done())
    if prev:
        d = bytearray()
        for c, p in zip(cur, prev):
            for i in range(1,7): varint(zz(c[i]-p[i]), d)
        frames["delta aligned q (zigzag varint)"].append(bytes(d))
        bw = BW()
        for c, p in zip(cur, prev):
            ch = [c[i] != p[i] for i in range(1,7)]
            if not any(ch): bw.w(0,1); continue
            bw.w(1,1)
            for i, f in enumerate(ch): bw.w(1 if f else 0, 1)
            for i in range(1,7):
                if c[i] != p[i]:
                    dv = c[i]-p[i]
                    if i in (1,3):
                        if -64 <= dv < 64: bw.w(0,1); bw.w(zz(dv),7)
                        else: bw.w(1,1); bw.w(c[i],16)
                    elif i == 2: bw.w(c[i],12)
                    elif i == 4: bw.w(c[i],8)
                    elif i == 5: bw.w(c[i],2)
                    else: bw.w(c[i],7)
        frames["delta bitpacked + dirty mask"].append(bw.done())
    prev = cur
# dictionary trained on first 200 frames of aligned q16
print(f"{'variant':36s} {'raw':>6s} {'zstd0':>6s} {'zstd1':>6s} {'zstd3':>6s} {'zstd19':>6s} {'dict3':>6s}")
for k, fs in frames.items():
    raw = sum(map(len, fs))/len(fs)
    res = []
    for lvl in (0, 1, 3, 19):
        c = zs.ZstdCompressor(level=lvl, write_content_size=True, write_checksum=False)
        res.append(sum(len(c.compress(f)) for f in fs)/len(fs))
    try:
        d = zs.train_dictionary(4096, fs[:200])
        c = zs.ZstdCompressor(level=3, dict_data=d)
        res.append(sum(len(c.compress(f)) for f in fs[200:])/len(fs[200:]))
    except Exception as ex: res.append(float('nan'))
    print(f"{k:36s} {raw:6.0f} " + " ".join(f"{r:6.0f}" for r in res))
