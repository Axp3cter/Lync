#!/usr/bin/env python3
"""Summarizes analyzer output for one probe. Usage: luau-analyze ... FILE 2>&1 | python3 -I summarize.py FILE
Prints: too-complex count; error lines among the correct calls (want none); EXPECT lines without an error (want none)."""
import re, sys
path = sys.argv[1]
src = open(path).read().split("\n")
mark = next(i for i, l in enumerate(src) if l.startswith("-- EXPECT")) + 1  # 1-based line of the marker
first_call = next(i for i, l in enumerate(src) if l.startswith("local h2")) + 1
expect = [i + 1 for i in range(mark, len(src)) if src[i].strip() and not src[i].startswith("return")]
errs = {}
complex_ = 0
for line in sys.stdin:
    m = re.match(r"\S+\((\d+),(\d+)\): (\w+): (.*)", line)
    if not m or m.group(3) == "LocalUnused":
        continue
    ln = int(m.group(1))
    if "too complex" in m.group(4):
        complex_ += 1
        continue
    errs.setdefault(ln, m.group(4)[:110])
bad_ok = sorted(l for l in errs if first_call <= l < mark)
missed = [l for l in expect if l not in errs]
other = sorted(l for l in errs if l < first_call)
print(f"too-complex: {complex_}; errors on correct calls: {bad_ok or 'none'}; EXPECT lines not rejected: {missed or 'none'}"
      + (f"; errors before the calls: {other}" if other else ""))
for l in bad_ok + other:
    print(f"  line {l}: {errs[l]}")
