#!/usr/bin/env python3
"""Claim 5: wall time of one luau-analyze / tsc process per probe. Usage: python3 -I time_check.py LUAU_ANALYZE
One warm-up run, then 9 timed runs per (probe, solver); prints median, min, max in ms. A baseline file (empty
--!strict module) is timed in the same run to give the process start-up cost."""
import os, statistics, subprocess, sys, time
A = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
os.chdir(HERE)
with open("empty.luau", "w") as f:
    f.write("--!strict\nreturn nil\n")
with open("ts/empty.ts", "w") as f:
    f.write("export {};\n")
def bench(cmd, runs=9):
    subprocess.run(cmd, capture_output=True)
    ts = []
    for _ in range(runs):
        t = time.perf_counter(); subprocess.run(cmd, capture_output=True); ts.append((time.perf_counter() - t) * 1000)
    return statistics.median(ts), min(ts), max(ts)
for probe in ("empty.luau", "base_overloads_128.luau", "b_table_128.luau", "b_consumer_128.luau", "a_explicit_128.luau",
              "e_phantom_32.luau", "f_codec_128.luau"):
    for solver in ("new", "old"):
        med, lo, hi = bench([A, f"--solver={solver}", probe])
        print(f"{probe:26} --solver={solver}: median {med:7.1f} ms  (min {lo:7.1f}, max {hi:7.1f})")
for probe in ("ts/empty.ts", "ts/use_128.ts", "ts/generic_128.ts", "ts/table_128.ts"):
    med, lo, hi = bench(["tsc", "--ignoreConfig", "--strict", "--noEmit", probe], runs=5)
    print(f"{probe:26} tsc --strict: median {med:7.1f} ms  (min {lo:7.1f}, max {hi:7.1f})")
