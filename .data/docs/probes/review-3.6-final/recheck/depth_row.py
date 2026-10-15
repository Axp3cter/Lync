#!/usr/bin/env python3
"""The DEPTH row after the final pass (v5.md §4.6: namespace index EG0, wire id u(w), depth u5).
Usage: python3 -I depth_row.py   (imports ../wire.py)
Prints the row's bits for namespace indices 1-6 and id widths 0-10, and one whole frame for the trace's `move`."""
import importlib.util, os
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("wire", os.path.join(here, "..", "wire.py"))
wire = importlib.util.module_from_spec(spec); spec.loader.exec_module(wire)


def eg0_bits(x):
    return 2 * ((x + 1).bit_length() - 1) + 1


print("row bits (ns index x id width), alone it adds the control chunk's 4 bits of type and count:")
for ns in (1, 2, 3, 6):
    print(f"  ns {ns}:", [eg0_bits(ns) + w + 5 for w in range(0, 11)])
w = wire.Bits()
w.u(1, 0); w.eg0(0); w.eg0(1); w.eg0(0); w.eg0(0); w.eg0(0); w.align()
w.u(3, 4); w.eg0(0); w.eg0(1); w.u(2, 2); w.u(5, 2); w.align()
print("down reliable, tick unchanged, one DEPTH (ns 1, move = up id 2 of 2 bits, depth 2):", wire.hexs(w.tobytes()))
