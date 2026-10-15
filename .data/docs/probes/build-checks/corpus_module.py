# Writes corpus.luau (a module returning the UTF-8 files of a list as strings) for bench_scan.luau.
# Usage: python3 -I corpus_module.py LIST OUT.luau
import sys
out = ["return {"]
for p in open(sys.argv[1]).read().split():
    b = open(p, "rb").read()
    try:
        s = b.decode("utf-8")
    except UnicodeDecodeError:
        continue
    eq = "="
    while ("]" + eq + "]") in s:
        eq += "="
    out.append("[" + eq + "[\n" + s + "]" + eq + "],")
out.append("}")
open(sys.argv[2], "w").write("\n".join(out))
