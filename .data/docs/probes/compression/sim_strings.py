"""Q5: strings. Inline vs static vocabulary vs per-connection interning (append-only
and LRU), alone and inside a frame that engine zstd compresses.

String sources per model (traffic.py): tycoon notifications ("X upgraded to level N!"),
labels and purchases (Zipf over 200 item names), chat (free text, ~unique); MMO entity
names on entering relevancy (14 NPC names + 30 player names); shooter kill feed
("A eliminated B").

Strategies (byte-aligned, LEB128 lengths and ids):
  inline       len + bytes every time
  static       strings found in the schema's vocabulary (items, NPC names) become a
               varint id; everything else inline (1 tag byte decides)
  intern-AO    per-connection append-only table, reliable lane: tag 0 = new literal
               (receiver assigns the next id), tag id+1 = known; cap 4096 then literals
  intern-LRU   same with an LRU table of 64 slots; both ends run the same LRU, so no
               eviction messages are needed on the ordered reliable lane
  intern-AO+t  intern-AO but fields marked transient (chat) are never interned
  template     notifications/killfeed sent as template id + args (a schema feature)

"inside frame" = marginal engine-zstd cost of the strings when appended to that model's
byte-aligned state section (dlt_col_varint), i.e. engine(state+strings) - engine(state).

Usage: PYTHONPATH=<zstandard dir> python3 sim_strings.py
"""
import re
from collections import OrderedDict

import traffic
from layouts import Layout
from wire import leb128, engine_len

VOCAB = set(traffic.ITEMS) | set(traffic.NPC_NAMES)
VOCAB_ID = {s: i for i, s in enumerate(sorted(VOCAB))}


class Interner:
    def __init__(self, cap, lru):
        self.cap, self.lru = cap, lru
        self.table = OrderedDict()
        self.next = 0

    def encode(self, s, out, transient=False):
        if s in self.table:
            sid = self.table[s]
            if self.lru:
                self.table.move_to_end(s)
            leb128(sid + 1, out)
            return
        out.append(0)
        b = s.encode()
        leb128(len(b), out)
        out += b
        if transient:
            return
        if len(self.table) < self.cap:
            self.table[s] = self.next
            self.next += 1
        elif self.lru:
            old, sid = self.table.popitem(last=False)
            self.table[s] = sid


def inline(s, out):
    b = s.encode()
    leb128(len(b), out)
    out += b


TEMPLATES = [
    (re.compile(r"^(.+) upgraded to level (\d+)!$"), 1),
    (re.compile(r"^(.+) eliminated (.+)$"), 2),
]


def template(s, out, interner):
    for rx, tid in TEMPLATES:
        mt = rx.match(s)
        if mt:
            out.append(tid)
            for g in mt.groups():
                if g.isdigit():
                    leb128(int(g), out)
                else:
                    interner.encode(g, out)
            return
    out.append(0)
    interner.encode(s, out, transient=False)


def run(model, hz, frames):
    m = traffic.MODELS[model](hz=hz, seed=51)
    fr = [m.step() for _ in range(frames)]
    lay = Layout(m)
    strategies = ["inline", "static", "intern-AO", "intern-LRU", "intern-AO+t", "template"]
    st = {k: dict(raw=0, alone=0, inframe=0, nonempty=0) for k in strategies}
    ao, lru, aot, tpl = Interner(4096, False), Interner(64, True), Interner(4096, False), Interner(4096, False)
    for i in range(1, len(fr)):
        f = fr[i]
        if not f.strings:
            continue
        base = lay.dlt_col_varint(fr, i, 1)
        eb = engine_len(base, 3)
        outs = {k: bytearray() for k in strategies}
        for ctx, s in f.strings:
            inline(s, outs["inline"])
            if s in VOCAB_ID:
                outs["static"].append(1)
                leb128(VOCAB_ID[s], outs["static"])
            else:
                outs["static"].append(0)
                inline(s, outs["static"])
            ao.encode(s, outs["intern-AO"])
            lru.encode(s, outs["intern-LRU"])
            aot.encode(s, outs["intern-AO+t"], transient=(ctx == "chat"))
            if ctx == "chat":
                outs["template"].append(0)
                outs["template"].append(0)
                inline(s, outs["template"])
            else:
                template(s, outs["template"], tpl)
        for k in strategies:
            b = bytes(outs[k])
            st[k]["raw"] += len(b)
            st[k]["alone"] += engine_len(b, 3)
            st[k]["inframe"] += engine_len(base + b, 3) - eb
            st[k]["nonempty"] += 1
    n = sum(1 for f in fr if f.strings)
    secs = frames / hz
    print(f"\n{model} @ {hz} Hz, {secs:.0f} s, {n} frames carry strings; bytes per second of strings:")
    print(f"  {'strategy':12s} {'raw':>8s} {'alone+z':>8s} {'in frame+z':>10s}   table size: AO {len(ao.table)}, "
          f"AO+t {len(aot.table)}")
    for k in strategies:
        print(f"  {k:12s} {st[k]['raw']/secs:8.1f} {st[k]['alone']/secs:8.1f} {st[k]['inframe']/secs:10.1f}")


if __name__ == "__main__":
    run("tycoon", 10, 3000)
    run("mmo", 20, 3000)
    run("shooter", 20, 3000)
