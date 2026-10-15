#!/usr/bin/env python3
"""List every option-table row of the five files (name, file§, type, unit, range, default) and flag C5 breaks.

Usage: python3 -I options.py <design-dir>
A row is an option row when its table's header has Option/Key and Unit columns.
"""
import os, re, sys
FILES = ["v5.md", "v5-integrity.md", "v5-collections.md", "v5-checks.md", "v5-tooling.md"]
HEAD = re.compile(r"^(#{2,4})\s+(\d+(?:\.\d+)*)\.?\s")
rows = []
for fn in FILES:
    sec = "0"; cols = None
    for line in open(os.path.join(sys.argv[1], fn), encoding="utf-8"):
        m = HEAD.match(line)
        if m: sec = m.group(2)
        s = line.strip()
        if not s.startswith("|"):
            cols = None; continue
        cells = [c.strip() for c in s.strip("|").split("|")]
        if cols is None:
            cols = [c.lower() for c in cells]; continue
        if set(cells[0]) <= set("-: "): continue
        if not (("option" in cols[0] or "key" in cols[0] or "counter" in cols[0] or "parameter" in cols[0] or "marker" in cols[0]) and "unit" in cols):
            continue
        rec = dict(zip(cols, cells))
        names = re.findall(r"`([^`]+)`", cells[0]) or [cells[0]]
        for nm in names:
            rows.append((nm, f"{fn}§{sec}", rec.get("type", ""), rec.get("unit", ""), rec.get("range", ""), rec.get("default", "")))
out = open("options.tsv", "w")
for r in rows:
    out.write("\t".join(r) + "\n")
print(len(rows), "option rows")
for nm, loc, ty, unit, rng, dflt in rows:
    u = unit.strip()
    leaf = nm.split(".")[-1]
    if u == "s" and not leaf.endswith("Seconds"):
        print("C5 duration without Seconds:", nm, loc)
    if u == "B" and not (leaf.endswith("Bytes") or nm.startswith("inbound.")):
        print("C5 size without Bytes:", nm, loc)
    if u in ("Hz",):
        print("C5 rate in Hz:", nm, loc)
seen = {}
for nm, loc, ty, unit, rng, dflt in rows:
    seen.setdefault(nm, []).append((loc, rng, dflt))
for nm, v in seen.items():
    if len(v) > 1 and len(set((r, d) for _, r, d in v)) > 1:
        print("defined twice with different range/default:", nm, v)
