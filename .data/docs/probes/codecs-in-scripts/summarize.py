"""Summarises bench.out (JSON lines, possibly several passes) into a Markdown table: for each definition,
scenario and form, the median over passes of each pass's median ns per call; the lowest per-pass minimum in
brackets."""
import json, sys, statistics
from collections import defaultdict
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip().endswith("}")]
med, mn = defaultdict(list), defaultdict(list)
for r in rows:
    k = (r["def"], r["scenario"], r["form"])
    med[k].append(r["ns"]); mn[k].append(r["min"])
forms = [f for f in ["S0", "S1", "W3", "W1", "W1n", "W1t", "W2", "D0", "D1"] if any(k[2] == f for k in med)]
keys = sorted({(k[0], k[1]) for k in med})
print("| def | scenario | " + " | ".join(forms) + " |")
print("|---|---|" + "---|" * len(forms))
for d, s in keys:
    cells = []
    for f in forms:
        k = (d, s, f)
        cells.append(f"{statistics.median(med[k]):.0f} [{min(mn[k]):.0f}]" if k in med else "")
    print(f"| {d} | {s} | " + " | ".join(cells) + " |")
