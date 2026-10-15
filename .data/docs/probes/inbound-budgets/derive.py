"""Claims 3 and 4: from the measured per-frame costs to worst-case inbound CPU per player for any budget values.

Reads decode_shapes.out and tag_frames.out (3 runs per mode), takes per case the median of the run medians, and
writes derive.out. Stdlib only. Run: python3 -I derive.py > derive.out

Model (per player, per second; v5.md §6.1, §7.5):
- An attacker chooses how many frames of each kind j to send per second, x_j >= 0. Kind j is a frame the probes
  timed: its lane, bytes b_j (tag included), elements e_j and server CPU c_j (decode_shapes F = shape, buckets,
  tag, decode, step 5; or tag_frames' wrong-tag frames, which are paid for and then refused at the tag).
- Paid frames are limited by the five buckets: sum over a lane of x_j <= frames.perSecond, of x_j b_j <=
  bytes.perSecond, and over both lanes of x_j e_j <= elements.perSecond. For the first second after an idle
  period, each limit is perSecond + burst.
- Worst-case CPU = the linear program max sum c_j x_j under those five limits. It is homogeneous of degree 1 in
  the limits (scaling every limit by a scales the optimum by a), and at the optimum
  CPU = sum_k lambda_k * limit_k exactly, lambda_k being the shadow price (ns per frame, per byte, per element)
  of limit k (LP duality). That sum is the formula from budget values to CPU, valid while the same limits bind.
- Frames a reliable lane refuses at the buckets are still tag-checked (v5.md §6.1 step 2) and use no budget:
  they are outside the LP and reported per engine-delivered frame.
- Generated path: c_j(gen) = G_j + (F_j - D_j) - tagM(b_j) + tagGu(b_j): the generated decode replaces the
  milestone decode, the unrolled generated tag replaces the milestone tag, and step 5 and the buckets stay the
  milestone's (not generated, so an upper figure for a generated build).
"""
import os
import re
import statistics

HERE = os.path.dirname(os.path.abspath(__file__))
MODES = ("native", "interpreted")

DEFAULTS = {  # v5.md §7.5: (perSecond, burst)
    "reliable.frames": (120, 240),
    "reliable.bytes": (32768, 65536),
    "unreliable.frames": (240, 480),
    "unreliable.bytes": (32768, 65536),
    "elements": (20000, 65536),
}
LIMITS = list(DEFAULTS)


def mode_of(header):
    return "native" if "codegen" in header else "interpreted"


def parse_decode():
    runs = {m: [] for m in MODES}
    cur = None
    for line in open(os.path.join(HERE, "decode_shapes.out")):
        if line.startswith("=="):
            cur = {}
            runs[mode_of(line)].append(cur)
            continue
        if cur is None or "|" not in line or line.startswith("frame "):
            continue
        parts = [p.strip() for p in line.split("|")]
        m = re.match(r"^(.*?)\s+(\d)\s+(\d+)\s+(\d+)\s+(\d+)$", parts[0])
        if not m:
            continue
        name = m.group(1)
        row = {"lane": int(m.group(2)), "bytes": int(m.group(3)), "msgs": int(m.group(4)), "elements": int(m.group(5))}
        for key, cell in zip(("D", "DP", "F", "G"), parts[1:5]):
            row[key] = float(cell.split()[0]) if cell != "-" else None
        cur[name] = row
    return runs


def parse_tag():
    runs = {m: [] for m in MODES}
    cur = None
    section = None
    for line in open(os.path.join(HERE, "tag_frames.out")):
        if line.startswith("=="):
            cur = {"A": [], "B": []}
            runs[mode_of(line)].append(cur)
            continue
        if line.startswith("## A"):
            section = "A"
            continue
        if line.startswith("## B"):
            section = "B"
            continue
        if cur is None or "|" not in line or line.startswith("lane"):
            continue
        parts = [p.strip() for p in line.split("|")]
        lane, size = (int(x) for x in parts[0].split())
        vals = [float(c.split()[0]) if c != "-" else None for c in parts[1:4]]
        cur[section].append((lane, size, vals))
    return runs


def agg(values):
    values = [v for v in values if v is not None]
    if not values:
        return None
    return statistics.median(values), min(values), max(values)


# --- LP: max c.x subject to A x <= b, x >= 0 (b >= 0), dense tableau simplex with Bland's rule ---------------------
def simplex(c, A, b):
    m, n = len(A), len(c)
    T = [list(A[i]) + [1.0 if k == i else 0.0 for k in range(m)] + [float(b[i])] for i in range(m)]
    z = [-float(x) for x in c] + [0.0] * m + [0.0]
    basis = [n + i for i in range(m)]
    for _ in range(10000):
        enter = next((j for j in range(n + m) if z[j] < -1e-12), None)
        if enter is None:
            break
        best, leave = None, None
        for i in range(m):
            if T[i][enter] > 1e-12:
                ratio = T[i][-1] / T[i][enter]
                if best is None or ratio < best - 1e-15 or (abs(ratio - best) <= 1e-15 and basis[i] < basis[leave]):
                    best, leave = ratio, i
        if leave is None:
            raise ValueError("unbounded")
        piv = T[leave][enter]
        T[leave] = [v / piv for v in T[leave]]
        for i in range(m):
            if i != leave and abs(T[i][enter]) > 0:
                f = T[i][enter]
                T[i] = [a - f * p for a, p in zip(T[i], T[leave])]
        f = z[enter]
        z = [a - f * p for a, p in zip(z, T[leave])]
        basis[leave] = enter
    x = [0.0] * n
    for i, j in enumerate(basis):
        if j < n:
            x[j] = T[i][-1]
    duals = [z[n + i] for i in range(m)]
    return z[-1], x, duals


def solve(options, limits):
    """options: list of dicts with lane, bytes, elements, cpu (ns); limits: dict name -> value per second."""
    c = [o["cpu"] for o in options]
    A = []
    for name in LIMITS:
        row = []
        for o in options:
            if name == "reliable.frames":
                row.append(1.0 if o["lane"] == 0 else 0.0)
            elif name == "reliable.bytes":
                row.append(float(o["bytes"]) if o["lane"] == 0 else 0.0)
            elif name == "unreliable.frames":
                row.append(1.0 if o["lane"] == 1 else 0.0)
            elif name == "unreliable.bytes":
                row.append(float(o["bytes"]) if o["lane"] == 1 else 0.0)
            else:
                row.append(float(o["elements"]))
        A.append(row)
    value, x, duals = simplex(c, A, [limits[k] for k in LIMITS])
    return value, x, dict(zip(LIMITS, duals))


def main():
    dec = parse_decode()
    tag = parse_tag()
    out = []
    p = out.append

    for mode in MODES:
        p(f"#### {mode} (luau 0.742{' --codegen' if mode == 'native' else ''}), medians of {len(dec[mode])} runs "
          f"(range = min-max of the run medians)")
        names = list(dec[mode][0])
        shapes = {}
        for name in names:
            row = dict(dec[mode][0][name])
            for key in ("D", "DP", "F", "G"):
                row[key] = agg([r[name][key] for r in dec[mode]])
            shapes[name] = row
        # tag fits from part A medians: per lane, fixed + slope
        A = {}
        for i, (lane, size, _) in enumerate(tag[mode][0]["A"]):
            A[(lane, size)] = [agg([r["A"][i][2][k] for r in tag[mode]]) for k in range(3)]
        Bp = {}
        for i, (lane, size, _) in enumerate(tag[mode][0]["B"]):
            Bp[(lane, size)] = [agg([r["B"][i][2][k] for r in tag[mode]]) for k in range(3)]
        sizes = sorted(A)

        def tagfit(k, lane):
            pts = sorted((s, A[(l, s)][k][0]) for (l, s) in A if l == lane)
            (s0, t0), (s1, t1) = pts[0], pts[-1]
            if lane == 0:  # slope over the two largest reliable sizes, fixed = smallest frame
                (s1a, t1a), (s1, t1) = pts[-2], pts[-1]
                slope = (t1 - t1a) / (s1 - s1a)
            else:
                slope = (t1 - t0) / (s1 - s0)
            return t0, slope

        def tag_at(k, lane, b):
            fixed, slope = tagfit(k, lane)
            smallest = min(s for (l, s) in A if l == lane)
            return fixed + slope * (b - smallest)

        p("")
        p("## Claim 2: tag per frame (one hash, cover 16,384), ns: median (range)")
        p(f"{'lane':>4} {'bytes':>6} | {'milestone Tag.compute':>28} | {'generated loop':>28} | {'generated unrolled x4':>28}")
        for (lane, size) in sizes:
            cells = [f"{v[0]:9.0f} ({v[1]:7.0f}-{v[2]:7.0f})" for v in A[(lane, size)]]
            p(f"{lane:>4} {size:>6} | {cells[0]:>28} | {cells[1]:>28} | {cells[2]:>28}")
        for k, label in enumerate(("milestone", "generated loop", "generated unrolled")):
            f0, s0 = tagfit(k, 0)
            f1, s1 = tagfit(k, 1)
            p(f"tag fit, {label}: reliable {f0:.0f} ns + {s0:.2f} ns/B; unreliable {f1:.0f} ns + {s1:.2f} ns/B")
        p("")
        p("## Claim 2: wrong-tag frames through the milestone Inbound.receive (no decode), ns per frame")
        p(f"{'lane':>4} {'bytes':>6} | {'wrong tag':>26} | {'wrong tag, pending key':>26} | {'over budget, wrong, pending':>28} | hashes")
        for (lane, size), v in sorted(Bp.items()):
            cells = [f"{x[0]:9.0f} ({x[1]:7.0f}-{x[2]:7.0f})" if x else "-" for x in v]
            p(f"{lane:>4} {size:>6} | {cells[0]:>26} | {cells[1]:>26} | {cells[2]:>28} | "
              f"{'5 / 10 / 10' if lane == 0 else '3 / 6 / -'}")

        p("")
        p("## Claim 1 + 2: per frame, total inbound CPU (F) split into decode, step 5, tag and the rest; ns")
        p(f"{'frame':<52} {'lane':>4} {'B':>6} {'elem':>6} | {'F total':>9} {'D decode':>9} {'step 5':>8} {'tag(M)':>8} "
          f"{'rest':>7} | {'F ns/B':>8} {'F ns/el':>8} | {'G':>9} {'G ns/B':>7} {'gen total':>9} {'gen ns/B':>8} {'gen ns/el':>9}")
        options = {"milestone": [], "generated": []}
        for name, s in shapes.items():
            lane, b, e = s["lane"], s["bytes"], s["elements"]
            F, D, DP = s["F"][0], s["D"][0], s["DP"][0]
            tM = tag_at(0, lane, b)
            tG = tag_at(2, lane, b)
            step5 = DP - D
            rest = F - DP - tM
            gen = None
            if s["G"] is not None:
                gen = s["G"][0] + (F - D) - tM + tG
            s["gen"] = gen
            per = lambda x, n: f"{x / n:8.1f}" if (x is not None and n) else f"{'-':>8}"
            gcell = f"{s['G'][0]:9.0f}" if s["G"] else f"{'-':>9}"
            p(f"{name:<52} {lane:>4} {b:>6} {e:>6} | {F:9.0f} {D:9.0f} {step5:8.0f} {tM:8.0f} {rest:7.0f} | "
              f"{per(F, b)} {per(F, e)} | {gcell} {per(s['G'][0] if s['G'] else None, b):>7} "
              f"{(f'{gen:9.0f}' if gen else f'{chr(45):>9}')} {per(gen, b)} {per(gen, e):>9}")
            p(f"{'':<52} {'':>4} {'':>6} {'':>6} | range F {s['F'][1]:.0f}-{s['F'][2]:.0f}, D {s['D'][1]:.0f}-{s['D'][2]:.0f}"
              + (f", G {s['G'][1]:.0f}-{s['G'][2]:.0f}" if s["G"] else ""))
            for path, cpu in (("milestone", F), ("generated", gen)):
                if cpu is not None:
                    options[path].append({"name": name, "lane": lane, "bytes": b, "elements": e, "cpu": cpu})
        # wrong-tag paid frames (pending key: the worst a client can put its own connection in)
        for (lane, size), v in sorted(Bp.items()):
            cpu = v[1][0]
            nh = 10 if lane == 0 else 6
            gen = cpu - nh * tag_at(0, lane, size) + nh * tag_at(2, lane, size)
            for path, c in (("milestone", cpu), ("generated", gen)):
                options[path].append({"name": f"wrong tag, pending key, {size} B", "lane": lane, "bytes": size,
                                      "elements": 0, "cpu": c})
        # the milestone's unreliable lane has no bools32 frame; a game can declare one there. Add an unreliable
        # 1000 B bools32 frame scaled from the reliable one's per-byte cost (bytes and elements in proportion)
        for path in ("milestone", "generated"):
            ref = next(o for o in options[path] if o["name"].startswith("bools32 x") and "random" in o["name"])
            k = 1000 / ref["bytes"]
            options[path].append({"name": "bools32 random, unreliable 1000 B (scaled)", "lane": 1, "bytes": 1000,
                                  "elements": round(ref["elements"] * k), "cpu": ref["cpu"] * k + 0.0})

        # busy model ---------------------------------------------------------------------------------------------
        bi = shapes["busy input: 1 move6, unreliable"]
        ba = shapes["busy action: 1 sm (8-byte name), reliable"]
        busy = {
            "reliable.frames": 10, "unreliable.frames": 60,
            "reliable.bytes": 10 * ba["bytes"], "unreliable.bytes": 60 * bi["bytes"], "elements": 70,
        }
        busy_design = dict(busy)
        busy_design["reliable.bytes"] = 10 * (ba["bytes"] + 2)
        busy_design["unreliable.bytes"] = 60 * (bi["bytes"] + 2) + 20 * 28 / 8
        busy_cpu = {"milestone": 60 * bi["F"][0] + 10 * ba["F"][0], "generated": 60 * bi["gen"] + 10 * ba["gen"]}
        p("")
        p("## Claim 3: the busy model (v5.md §4.1: 60 input frames unreliable + 10 action frames reliable per second;")
        p("   input = move6, action = sm with an 8-byte name; each frame one message)")
        p(f"busy input frame {bi['bytes']} B, action frame {ba['bytes']} B (milestone: 16-bit tag, no ack)")
        for path in ("milestone", "generated"):
            c = busy_cpu[path]
            p(f"busy CPU per player, {path}: {c / 1e3:.1f} us/s; at 100 players {c * 100 / 1e6:.2f} ms/s = "
              f"{c * 100 / 1e9 * 100:.3f}% of one core")
        p(f"{'budget':<20} {'default perSecond':>17} {'busy use':>10} {'fraction':>9} | {'design use':>10} {'fraction':>9} | "
          f"{'burst':>8} {'largest busy frame / burst':>27}")
        for k in LIMITS:
            ps, burst = DEFAULTS[k]
            largest = {"reliable.frames": 1, "unreliable.frames": 1, "reliable.bytes": ba["bytes"] + 2,
                       "unreliable.bytes": bi["bytes"] + 2 + 4, "elements": 1}[k]
            p(f"{k:<20} {ps:>17} {busy[k]:>10.0f} {busy[k] / ps:>9.4f} | {busy_design[k]:>10.0f} {busy_design[k] / ps:>9.4f} | "
              f"{burst:>8} {largest / burst:>27.6f}")

        # worst case ---------------------------------------------------------------------------------------------
        schemas = {
            "S1 busy-like (move6, sm, text, no-payload events)":
                lambda o: not (o["name"].startswith("bools") or o["name"].startswith("array") or o["name"].startswith("rec1")),
            "S2 S1 + rec1 + arrays (R31's shapes)":
                lambda o: not o["name"].startswith("bools"),
            "S3 S2 + a 32-bool record (bools32)":
                lambda o: not o["name"].startswith("bools128"),
            "S4 S3 + a 128-bool record (bools128)":
                lambda o: True,
        }
        p("")
        p("## Claim 3: worst-case CPU per player at the defaults (LP over the timed frames), and its formula")
        p("   formula: CPU = sum over limits of (shadow price x limit), exact at these limits; zero-price limits don't bind")
        results = {}
        for path in ("milestone", "generated"):
            for sname, keep in schemas.items():
                opts = [o for o in options[path] if keep(o)]
                for label, lim in (("sustained (perSecond)", {k: DEFAULTS[k][0] for k in LIMITS}),
                                   ("first second (perSecond + burst)", {k: DEFAULTS[k][0] + DEFAULTS[k][1] for k in LIMITS})):
                    v, x, duals = solve(opts, lim)
                    results[(path, sname, label)] = (v, x, duals, opts)
                    used = ", ".join(f"{x[i]:.1f}/s {opts[i]['name']}" for i in range(len(opts)) if x[i] > 1e-9)
                    terms = " + ".join(f"{duals[k]:.3g} ns x {k}" for k in LIMITS if duals[k] > 1e-9)
                    p(f"[{path}] {sname}, {label}: {v / 1e6:.2f} ms/s per player; 100 players {v * 100 / 1e9:.3f} s/s "
                      f"= {v * 100 / 1e9 * 100:.1f}% of one core")
                    p(f"    = {terms}")
                    p(f"    attack mix: {used}")

        # claim 4 --------------------------------------------------------------------------------------------------
        p("")
        p("## Claim 4: budget values at which worst-case CPU at 100 players = 1%, 5%, 10% of one core")
        p("   (a) every perSecond scaled by one factor a (LP is homogeneous: a = target / CPU at defaults);")
        p("   (b) one budget varied, the others at their defaults (bisection; 'floor' = the CPU with that budget at 0).")
        targets = (0.01, 0.05, 0.10)
        for path in ("milestone", "generated"):
            for sname, keep in schemas.items():
                opts = [o for o in options[path] if keep(o)]
                base = {k: DEFAULTS[k][0] for k in LIMITS}
                v0 = solve(opts, base)[0]
                p(f"[{path}] {sname}: defaults give {v0 * 100 / 1e9 * 100:.1f}% of one core at 100 players")
                for tgt in targets:
                    per_player = tgt * 1e9 / 100  # ns per second per player
                    a = per_player / v0
                    vals = ", ".join(f"{k} {base[k] * a:.4g}" for k in LIMITS)
                    p(f"  (a) {tgt * 100:.0f}%: a = {a:.4f}: {vals}")
                for k in LIMITS:
                    cells = []
                    lim0 = dict(base)
                    lim0[k] = 0
                    floor = solve(opts, lim0)[0]
                    for tgt in targets:
                        per_player = tgt * 1e9 / 100
                        if floor >= per_player:
                            cells.append(f"{tgt * 100:.0f}%: unreachable (floor {floor * 100 / 1e9 * 100:.1f}%)")
                            continue
                        lo, hi = 0.0, base[k]
                        while solve(opts, {**base, k: hi})[0] < per_player and hi < base[k] * 1e6:
                            hi *= 2
                        if solve(opts, {**base, k: hi})[0] < per_player:
                            cells.append(f"{tgt * 100:.0f}%: above every value (saturates)")
                            continue
                        for _ in range(60):
                            mid = (lo + hi) / 2
                            if solve(opts, {**base, k: mid})[0] < per_player:
                                lo = mid
                            else:
                                hi = mid
                        cells.append(f"{tgt * 100:.0f}%: {hi:.4g}")
                    p(f"  (b) {k:<18} default {base[k]:>6}: " + "; ".join(cells))
                # the floor any budget set admitting the busy model has: budgets equal to the busy model's use
                vb = solve(opts, {k: busy_design[k] for k in LIMITS})[0]
                p(f"  floor: budgets equal to the busy model's own use (design bytes) still admit {vb / 1e3:.0f} us/s per "
                  f"player = {vb * 100 / 1e9 * 100:.2f}% of one core at 100 players")
        # outside the LP: over-budget reliable frames
        p("")
        p("## Outside every budget: reliable frames refused at the buckets are still tag-checked (v5.md §6.1 step 2)")
        for (lane, size), v in sorted(Bp.items()):
            if lane == 0 and v[2]:
                c = v[2][0]
                p(f"over-budget reliable {size} B frame, wrong tag, pending key: {c / 1e3:.1f} us per engine-delivered frame "
                  f"(milestone); at 500 frames/s per client {c * 500 / 1e6:.1f} ms/s per player, "
                  f"{c * 500 * 100 / 1e9 * 100:.0f}% of one core at 100 players")
        p("")
    print("\n".join(out))


main()
