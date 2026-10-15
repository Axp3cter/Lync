# Generates straight-line Luau encoders of growing size to find where Luau 0.742's
# compiler limits bite (locals, registers, constants per function, closures per proto).
# Usage: python3 -I gen_limits.py OUTDIR
import sys, os
out = sys.argv[1]
os.makedirs(out, exist_ok=True)

def write(name, src):
    with open(os.path.join(out, name), "w") as f:
        f.write(src)

# 1. One encoder function with N distinct numeric constants (per-build tag/field constants).
for n in (200, 255, 256, 1000, 40000):
    lines = ["--!strict", "local M = {}", "function M.enc(b: buffer, o: number, x: number): number"]
    for i in range(n):
        lines.append(f"\tbuffer.writeu32(b, o + {i * 4 % 4096}, bit32.bxor(x, {0x10000 + i * 7919}))")
    lines += ["\treturn o", "end", "return M"]
    write(f"consts_{n}.luau", "\n".join(lines) + "\n")

# 2. N top-level local functions (one per definition) vs a table of functions.
for n in (199, 201):
    lines = ["local M = {}"]
    for i in range(n):
        lines.append(f"local function f{i}(b: buffer, o: number) buffer.writeu8(b, o, {i % 256}) end")
    lines.append("return M")
    write(f"locals_{n}.luau", "\n".join(lines) + "\n")

# 3. A record encoder with N fields held in locals before writing (register pressure).
for n in (190, 260):
    lines = ["local M = {}", "function M.enc(b: buffer, v: {[string]: number})"]
    for i in range(n):
        lines.append(f"\tlocal a{i} = v.f{i}")
    for i in range(n):
        lines.append(f"\tbuffer.writeu8(b, {i}, a{i})")
    lines += ["end", "return M"]
    write(f"regs_{n}.luau", "\n".join(lines) + "\n")

# 4. N definitions as table fields of one module (the shard shape): closures per proto.
for n in (2000, 33000):
    lines = ["local M = {}"]
    for i in range(n):
        lines.append(f"M.d{i} = function(b: buffer, o: number) buffer.writeu8(b, o, {i % 256}) end")
    lines.append("return M")
    write(f"closures_{n}.luau", "\n".join(lines) + "\n")
