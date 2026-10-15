"""Summarise <probe>.out files written by run.sh: per mode (interpreted / native), per comparison and case, the
median of the per-run medians, its range over runs, and the median per-run ratio to the baseline.
Usage: python3 -I summarize.py probe.out [...]"""
import re, statistics, sys
from collections import OrderedDict

for path in sys.argv[1:]:
    data = OrderedDict()  # (mode, title) -> case -> [(median, ratio)]
    mode = title = None
    for line in open(path):
        m = re.match(r"== \S+, \S+ (-O2(?: --codegen)?), run (\d+)", line)
        if m:
            mode = "native" if "codegen" in m.group(1) else "interp"
            continue
        m = re.match(r"## (.*?) \(\d+ iters", line)
        if m:
            title = m.group(1)
            continue
        m = re.match(r"(.{34,40}?) +([\d.]+) +([\d.]+) +([\d.]+) +([\d.]+) +([\d.]+) +([\d.]+)$", line.rstrip("\n"))
        if m and mode and title:
            data.setdefault((mode, title), OrderedDict()).setdefault(m.group(1).strip(), []).append((float(m.group(2)), float(m.group(5))))
    print(f"# {path}")
    for (mode, title), cases in data.items():
        print(f"## [{mode}] {title}")
        for case, runs in cases.items():
            meds = [r[0] for r in runs]
            rats = [r[1] for r in runs]
            print(f"  {case:36} {statistics.median(meds):11.2f} ns ({min(meds):.2f}-{max(meds):.2f}, {len(runs)} runs)  ratio {statistics.median(rats):.2f} ({min(rats):.2f}-{max(rats):.2f})")
