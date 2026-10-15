"""Q2 follow-up: one buffer or two? A bit-packed state section (col_bits_pred, mostly
incompressible) plus a byte-aligned string section (inline strings, compressible text).

  one    engine(state || strings)                      single buffer argument
  two    engine(state) + engine(strings) + 2           two buffer arguments (+2 B for the
                                                       second argument's tag and length)
  ideal  min over the two per frame (+1 bit flag ignored)

Usage: PYTHONPATH=<zstandard dir> python3 sim_mixed.py
"""
import traffic
from layouts import Layout
from wire import engine_len, leb128


def strings_section(f):
    out = bytearray()
    for _, s in f.strings:
        b = s.encode()
        leb128(len(b), out)
        out += b
    return bytes(out)


for model, kw in (("tycoon", dict(hz=10)), ("shooter", dict(hz=20)), ("mmo", dict(hz=20))):
    m = traffic.MODELS[model](seed=61, **kw)
    fr = [m.step() for _ in range(1500)]
    lay = Layout(m)
    one = two = ideal = n = 0
    st_bytes = s_bytes = 0
    for i in range(3, len(fr)):
        if not fr[i].strings:
            continue
        st = lay.col_bits_pred(fr, i, 1)
        s = strings_section(fr[i])
        a = engine_len(st + s)
        b = engine_len(st) + engine_len(s) + 2
        one += a
        two += b
        ideal += min(a, b)
        st_bytes += len(st)
        s_bytes += len(s)
        n += 1
    print(f"{model:8s} frames with strings {n:4d}: state {st_bytes/n:6.1f} B + strings {s_bytes/n:6.1f} B raw | "
          f"one buffer {one/n:6.1f} | two buffers {two/n:6.1f} | per-frame best {ideal/n:6.1f}")
