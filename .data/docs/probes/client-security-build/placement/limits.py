"""A generated module with 210 top-level local functions: Luau's 200-locals limit (kMaxLocalCount) rejects it.
Usage: python3 -I limits.py <luau-compile> <outdir>"""
import os, subprocess, sys
lc, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
path = os.path.join(out, "locals.luau")
open(path, "w").write("".join(f"local function f{i}() return {i} end\n" for i in range(210)) + "return f1\n")
r = subprocess.run([lc, "--null", path], capture_output=True, text=True)
print(next(l for l in (r.stdout + r.stderr).splitlines() if "Error" in l))
