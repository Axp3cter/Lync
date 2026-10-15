"""Summarises bench.out (JSON lines) into a table: median ns per call by definition, scenario and form."""
import json, sys
from collections import defaultdict
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip().endswith("}")]
t = defaultdict(dict)
for r in rows:
    t[(r["def"], r["scenario"])][r["form"]] = r["ns"]
forms = [f for f in ["S0", "S1", "W3", "W1", "W1n", "W1t", "W2", "D0", "D1"] if any(f in d for d in t.values())]
print("| def | scenario | " + " | ".join(forms) + " |")
print("|---|---|" + "---|" * len(forms))
for k in sorted(t):
    d = t[k]
    print(f"| {k[0]} | {k[1]} | " + " | ".join(f"{d[f]:.0f}" if f in d else "" for f in forms) + " |")
