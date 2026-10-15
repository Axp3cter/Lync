#!/usr/bin/env python3
"""Recompute ROT's per-build draws from v5-integrity.md §2.2's text (streams, order, offsets, tag constants).

Usage: python3 -I draws.py   (imports wire.py from this directory for HalfSipHash)
"""
import importlib.util, os
spec = importlib.util.spec_from_file_location("wire", os.path.join(os.path.dirname(os.path.abspath(__file__)), "wire.py"))
wire = importlib.util.module_from_spec(spec); spec.loader.exec_module(wire)

SEED = 0x0123456789ABCDEF
KEY = SEED.to_bytes(8, "little")  # two u32, low first


def v64(label):
    return wire.halfsiphash(KEY, label.encode(), 2, 4, out64=True)


def stream(label):
    x = v64(label) & 0xFFFFFFFF
    if x == 0:
        x = 0x9E3779B9
    while True:
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        yield x


s = stream("order:arena.strike.data")
fields = ["aim", "target"]
for i in range(len(fields) - 1, 0, -1):
    j = next(s) % (i + 1)
    fields[i], fields[j] = fields[j], fields[i]
print("order:", fields, "| ROT: aim, target")
s = stream("offset:arena.strike.data.aim")
print("aim offsets:", next(s) % 2048, next(s) % 2048, "| ROT: 695, 1433")
s = stream("offset:arena.strike.data.target")
print("target offset:", next(s) % (1 << 40), "| ROT: 1953753273")
s = stream("tag")
print("tag constants: %08x %08x" % (next(s), next(s)), "| ROT: 6c116fc3 7cccc9d7")
S = v64("session") or 1
print("S = %016x" % S)
