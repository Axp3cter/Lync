#!/usr/bin/env python3
"""Recompute upstream and downstream frames from v5.md §4's text, independently of golden_wire.luau.

Usage: python3 -I wire.py
Rebuilds G3, G4, G4c and G8 (to check this reading of §4.1–§4.5 against the golden set), then the frames the
review's trace relies on: the reliable `strike` variant (strike'), identity build and generic ids, and with a
woven site id; and the per-build tag with a variant mask, to show which bytes a mask changes.
"""


class Bits:
    def __init__(self):
        self.bits = []

    def u(self, w, v):
        assert 0 <= v < (1 << w) if w else v == 0, (w, v)
        for i in range(w):
            self.bits.append((v >> i) & 1)

    def eg0(self, x):
        z = (x + 1).bit_length() - 1
        for _ in range(z):
            self.bits.append(0)
        self.bits.append(1)
        self.u(z, (x + 1) - (1 << z))

    def align(self):
        while len(self.bits) % 8:
            self.bits.append(0)

    def tobytes(self):
        assert len(self.bits) % 8 == 0
        out = bytearray()
        for i in range(0, len(self.bits), 8):
            b = 0
            for j in range(8):
                b |= self.bits[i + j] << j
            out.append(b)
        return bytes(out)


M32 = 0xFFFFFFFF


def rotl(x, b):
    return ((x << b) | (x >> (32 - b))) & M32


def halfsiphash(key8, data, c, d, out64=False, init=(0x6C796765, 0x74656462)):
    k0 = int.from_bytes(key8[0:4], "little")
    k1 = int.from_bytes(key8[4:8], "little")
    v0, v1, v2, v3 = k0, k1, init[0] ^ k0, init[1] ^ k1
    if out64:
        v1 ^= 0xEE

    def rnd():
        nonlocal v0, v1, v2, v3
        v0 = (v0 + v1) & M32; v1 = rotl(v1, 5); v1 ^= v0; v0 = rotl(v0, 16)
        v2 = (v2 + v3) & M32; v3 = rotl(v3, 8); v3 ^= v2
        v0 = (v0 + v3) & M32; v3 = rotl(v3, 7); v3 ^= v0
        v2 = (v2 + v1) & M32; v1 = rotl(v1, 13); v1 ^= v2; v2 = rotl(v2, 16)

    n = len(data)
    end = n - (n % 4)
    for i in range(0, end, 4):
        m = int.from_bytes(data[i:i + 4], "little")
        v3 ^= m
        for _ in range(c):
            rnd()
        v0 ^= m
    b = (n & 0xFF) << 24
    rest = data[end:]
    for i, x in enumerate(rest):
        b |= x << (8 * i)
    v3 ^= b
    for _ in range(c):
        rnd()
    v0 ^= b
    v2 ^= 0xEE if out64 else 0xFF
    for _ in range(d):
        rnd()
    lo = v1 ^ v3
    if not out64:
        return lo
    v1 ^= 0xDD
    for _ in range(d):
        rnd()
    hi = v1 ^ v3
    return lo | (hi << 32)


def tag(key8, count, lane, caller, frame, cover=1024, instances=0, mask=0, init=(0x6C796765, 0x74656462)):
    inp = count.to_bytes(4, "little") + bytes([lane + (128 if caller else 0)]) + len(frame).to_bytes(4, "little")
    inp += instances.to_bytes(2, "little") + frame[:min(cover, len(frame))]
    return (halfsiphash(key8, inp, 1, 3, init=init) ^ mask).to_bytes(4, "little")


KEY = bytes(range(8))


def up_reliable(chunks, caller=0, rcv=0):
    """chunks: list of (namespace, [run writer fns]) in call order; one segment per namespace here."""
    w = Bits()
    w.u(1, caller)
    w.u(1, 0)            # ack '0'
    w.u(8, rcv)
    w.eg0(len(chunks))   # n segments
    for ns, runs in chunks:
        w.eg0(ns)
        w.eg0(len(runs) - 1)
    for ns, runs in chunks:
        for run in runs:
            run(w)
    tail = []
    for ns, runs in chunks:
        for run in runs:
            tail.extend(getattr(run, "tail", []))
    w.align()
    return w.tobytes() + b"".join(reversed(tail))


def run_chat(text, idw=2, wid=1):
    def f(w):
        w.u(idw, wid)
        w.eg0(0)
        w.u(8, len(text))      # t.string(200): u(ceil(log2 201)) = 8
    f.tail = [text]
    return f


def strike_row(w, aim_codes, target, order=("aim", "target"), offs=None):
    offs = offs or {}
    n_t = 1 << 40
    q_t = target - 1
    for name in order:
        if name == "aim":
            for i, q in enumerate(aim_codes):
                c = offs.get(f"aim{i}", 0)
                w.u(11, (q + c) % 2048)
        else:
            c = offs.get("target", 0)
            w.u(40, (q_t + c) % n_t)


def run_strike(rows, idw=2, wid=2, order=("aim", "target"), offs=None):
    def f(w):
        w.u(idw, wid)
        w.eg0(len(rows) - 1)
        assert len(rows) < 3, "single rows only here"
        for aim, target in rows:
            strike_row(w, aim, target, order, offs)
    return f


def hexs(b):
    return " ".join(f"{x:02x}" for x in b)


def main():
    # G4: up reliable, count 0: chat:fire("gg")
    body = up_reliable([(1, [run_chat(b"gg")])])
    g4 = body + tag(KEY, 0, 0, 0, body)
    print("G4  ", hexs(g4), "| golden 00 48 2b 00 67 67 35 5e a9 22")
    body = bytearray(body); body[0] |= 1; body = bytes(body)
    g4c = body + tag(KEY, 0, 0, 1, body)
    print("G4c ", hexs(g4c), "| golden 01 48 2b 00 67 67 20 26 cc 0f")

    # G3: down reliable, tick unchanged: answer to buy, slot 0, epoch 0, value 250
    w = Bits()
    w.u(1, 0)                         # tick '0' unchanged
    w.eg0(0)                          # segs(state): none
    w.eg0(1); w.eg0(1); w.eg0(0)      # segs(run): one segment, ns 1, one chunk
    w.eg0(0)                          # segs(remove): none
    w.align()                         # downstream chunks start on a byte boundary
    w.u(1, 1)                         # down id: announce 0, buy 1 (1 bit)
    w.eg0(0)
    w.u(4, 0); w.u(1, 0); w.u(2, 0)   # slot, epoch, outcome 0 value
    w.u(17, 250)                      # reply t.int(0, 100000): u(ceil(log2 100001)) = 17
    w.align()
    print("G3  ", hexs(w.tobytes()), "| golden 4a 03 03 f4 01 00")

    # strike as a direction code pair: Vector3.zAxis at 11 bits -> (1024, 1024)? derive from the octahedral rule
    def octa(x, y, z, bits):
        s = abs(x) + abs(y) + abs(z)
        px, py = x / s, y / s
        if z < 0:
            sg = lambda v: 1 if v >= 0 else -1
            px, py = (1 - abs(py)) * sg(px), (1 - abs(px)) * sg(py)
        q = lambda c: int((c + 1) / 2 * ((1 << bits) - 1) + 0.5)
        return q(px), q(py)

    aim = octa(0, 0, 1, 11)
    print("aim zAxis at 11 bits:", aim)

    # G8: up unreliable, seq 0, ack '0', one run of four strike (column block) is not rebuilt here (column coder);
    # strike' (reliable, single row): count 0, target 5, aim zAxis, identity build, generic ids
    body = up_reliable([(1, [run_strike([(aim, 5)])])])
    fr = body + tag(KEY, 0, 0, 0, body)
    print("strike' identity, generic id:", len(fr), "B:", hexs(fr))
    # the same with the woven fixture's 3-bit up ids (D 3 + S 2): a site id 3 for a hypothetical strike site
    body = up_reliable([(1, [run_strike([(aim, 5)], idw=3, wid=3)])])
    fr = body + tag(KEY, 0, 0, 0, body)
    print("strike' woven site id 3 (3-bit ids):", len(fr), "B:", hexs(fr))
    # ROT's draws applied to a single row: order (aim, target), offsets aim 695, 1433, target 1,953,753,273
    offs = {"aim0": 695, "aim1": 1433, "target": 1953753273}
    body = up_reliable([(1, [run_strike([(aim, 5)], offs=offs)])])
    init = (0x6C116FC3, 0x7CCCC9D7)
    t0 = tag(KEY, 0, 0, 0, body, init=init)
    t1 = tag(KEY, 0, 0, 0, body, init=init, mask=0x5A5A1234)
    print("strike' ROT draws, single row:", hexs(body), "| tag mask 0:", hexs(t0), "| tag mask 0x5a5a1234:", hexs(t1))
    print("bits in strike' single-row frame body:", 10 + 3 + 3 + 1 + 2 + 1 + 22 + 40)
    # G5: up unreliable, seq 0, ack-only: state seq 5 received, with 4 and 3
    w = Bits()
    w.u(12, 0); w.u(1, 0)
    w.u(1, 1); w.u(12, 5); w.u(16, 0b11)   # ack '1' seq received (bit i is seq - 1 - i)
    w.u(1, 0)                              # receipt '0'
    w.eg0(0)                               # segs(run): none
    w.align()
    body = w.tobytes()
    print("G5  ", hexs(body + tag(KEY, 0, 1, 0, body)), "| golden 00 60 01 0c 00 08 56 2d c5 9a")


if __name__ == "__main__":
    main()


def down_patch(slot=5, health=90, team_class=False, ws=6):
    """Down reliable, tick unchanged: one fighters update {health} in a shared (partition) chunk, identity build.
    Reliable fields in name order: health, name, team, title (position and look are :newest())."""
    w = Bits()
    w.u(1, 0)                          # tick '0'
    w.eg0(1); w.eg0(1); w.eg0(0)       # segs(state): one segment, ns 1, one chunk
    w.eg0(0)                           # segs(run): none
    w.eg0(0)                           # segs(remove): none
    w.align()
    w.u(1, 0)                          # collection: fighters 0 of (fighters, round), wc = 1
    w.u(1, 0)                          # kind 0
    w.eg0(0)                           # adds: none
    w.eg0(1)                           # updates: one
    w.u(ws, slot)
    for f in ("health", "name", "team", "title"):
        w.u(1, 1 if f == "health" else 0)
    if team_class:
        w.u(1, 1)                      # class field coded as t.optional: present
    w.u(7, health)                     # t.int(0, 100): u7
    w.align()
    return w.tobytes()


if __name__ == "__main__":
    print("down patch health 90, slot 5:", hexs(down_patch()))
    print("down patch health 90, slot 5, health:team() in its team chunk:", hexs(down_patch(team_class=True)))
