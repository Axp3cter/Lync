"""Bytecode size of 50 call sites that each inline a record encoder, against 50 calls of one shared encoder.
Usage: python3 -I size.py <luau-compile> <outdir>"""
import os, subprocess, sys
lc, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
BODY = """\tbuffer.writeu16(b, o, v.target); o += 2
\tbuffer.writei32(b, o, math.round(v.aim.x / 0.01)); buffer.writei32(b, o + 4, math.round(v.aim.y / 0.01)); buffer.writei32(b, o + 8, math.round(v.aim.z / 0.01)); o += 12
\tbuffer.writeu8(b, o, math.round(v.charge * 255)); o += 1"""
shared = ["local function encode(b: buffer, o: number, v: any): number", BODY, "\treturn o", "end", "local M = {}"]
inline = ["local M = {}"]
for i in range(50):
    shared.append(f"function M.site{i}(b: buffer, o: number, v: any): number return encode(b, o, v) end")
    inline += [f"function M.site{i}(b: buffer, o: number, v: any): number", BODY, "\treturn o", "end"]
for name, lines in (("shared", shared), ("inline", inline)):
    path = os.path.join(out, name + ".luau")
    open(path, "w").write("\n".join(lines + ["return M"]) + "\n")
    for g in (0, 1):
        data = subprocess.run([lc, "--binary", "-O2", f"-g{g}", path], capture_output=True, check=True).stdout
        print(f"{name} -g{g}: {len(data)} bytes of bytecode, {os.path.getsize(path)} bytes of source")
