"""Claims 1-3 from decode_cost.out and tag_cost.out (7 native and 3 interpreted runs); writes derive.out. Stdlib only.
Run: python3 -I derive.py > derive.out

Terms (design/v5.md §7.5 as restructured mid-unit): each element (a message, an array element, a map pair, a control
row) costs w = ceil(p(L) / 100 ns) decode units, p(L) = p_0 + p_1 * L, L the element's own leaves; one frame costs
at most (1 + mu) * (c_f + c_b * charge + 100 ns * units). Per case, the figure of a mode is the median of its run
medians; "worst run" is the highest of the run medians (the spread the margin mu must cover).

- c_f, c_b (claim 2) come from tag_cost.out: c_f,r = the header-only reliable frame at its costliest position, c_b,r =
  the costliest (F - c_f,r - 100 ns * units of its one element) / (B - 3) over the string and buffer frames at every
  position and failing; c_f,u, c_b,u the same over the unreliable candidates; plus the instance-list walk per byte
  of charge (8 B per entry).
- The unit price (claim 1) is judged on each frame's excess over c_f + c_b * B at e + 4 (the costliest accepted
  position): excess = F_e4 - c_f,r - c_b,r * B, against 100 ns * units. For the generated path the frame is
  F_e4 - D + G (generated decode in place of the milestone's; tag, buckets and step 5 the milestone's).
- p(shape) (claim 1) is fitted as an upper envelope, by linear programming: per element p_0 + sum over node kinds of
  w_k * n_k ns, n_k the element's nodes of kind k outside the elements nested in it (decode_cost.luau's signatures),
  minimising the sum over frames of predicted / measured subject to predicted >= measured for every frame.
"""
import math
import os
import re
import statistics

HERE = os.path.dirname(os.path.abspath(__file__))
MODES = ("native", "interpreted")

# design weights in leaves (v5.md §7.5 restructured): node kind -> leaves
DESIGN_W = {
    "bool": 1, "int": 1, "varint": 1, "number": 1, "f32": 1, "f64": 1, "angle": 1, "enum": 1, "string": 1,
    "buffer": 1, "robloxEnum": 1, "instance": 1, "vector3": 3, "vector3f32": 3, "color3": 3, "direction": 2,
    "rotation": 4, "cframe": 7, "optional": 1, "union": 1, "array": 2, "map": 2, "record": 0,
}
KINDS = list(DESIGN_W)
P0_DESIGN, P1_DESIGN, UNIT = 2000.0, 133.0, 100.0
# draft 3.6 (before the restructure): per element p(L) = 2,000 + 133 L, arrays and maps 0 (outside nested), unions 0
V36_W = dict(DESIGN_W, array=0, map=0, union=0, optional=1, record=0)
V36_CF_R, V36_CB_R = 2530.0, 20.2


def mode_of(header):
    return "native" if "codegen" in header else "interpreted"


def triple(cell):
    a = cell.split("=")[1].split()
    return float(a[0])


def parse_decode():
    runs = {m: [] for m in MODES}
    cur = None
    for line in open(os.path.join(HERE, "decode_cost.out")):
        if line.startswith("=="):
            cur = {}
            runs[mode_of(line)].append(cur)
            continue
        if not line.startswith("CASE ") or cur is None:
            continue
        parts = [p.strip() for p in line[5:].split("|")]
        name = parts[0]
        meta = dict(kv.split("=") for kv in parts[1].split())
        row = {k: int(v) for k, v in meta.items()}
        for p in parts[2:6]:
            key = p.split("=")[0]
            row[key] = triple(p)
        sig = parts[6][len("sig="):]
        hist = []
        if sig:
            for item in sig.split(";"):
                s, mult = item.rsplit("*", 1)
                counts = {}
                if s:
                    for kv in s.split(","):
                        k, v = kv.split("=")
                        counts[k] = int(v)
                hist.append((counts, int(mult)))
        row["sig"] = hist
        cur[name] = row
    return runs


def parse_tag():
    runs = {m: [] for m in MODES}
    cur = None
    for line in open(os.path.join(HERE, "tag_cost.out")):
        if line.startswith("=="):
            cur = {}
            runs[mode_of(line)].append(cur)
            continue
        if cur is None or " F=" not in line:
            continue
        head, f = line.rsplit(" F=", 1)
        cur[head.strip()] = float(f.split()[0])
    return runs


def agg(runs, key=None):
    """{case: (median of run medians, max of run medians)} per mode."""
    out = {}
    for mode, rs in runs.items():
        names = set().union(*[set(r) for r in rs]) if rs else set()
        out[mode] = {}
        for n in names:
            vals = [r[n] if key is None else r[n][key] for r in rs if n in r]
            out[mode][n] = (statistics.median(vals), max(vals), min(vals))
    return out


def leaves(counts, weights):
    return sum(weights.get(k, 0) * v for k, v in counts.items())


def units_of(hist, weights, p0, p1):
    return sum(mult * math.ceil((p0 + p1 * leaves(c, weights)) / UNIT - 1e-9) for c, mult in hist)


def simplex(c, A, b):
    """max c.x s.t. A x <= b, x >= 0, b >= 0 (probes/inbound-budgets/derive.py). Returns value, x, duals."""
    m, n = len(A), len(c)
    T = [list(A[i]) + [1.0 if k == i else 0.0 for k in range(m)] + [float(b[i])] for i in range(m)]
    z = [-float(x) for x in c] + [0.0] * m + [0.0]
    basis = [n + i for i in range(m)]
    for _ in range(20000):
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


def upper_fit(frames, per_frame=False):
    """frames: [(features dict incl. 'p0' count, measured y)]; min sum pred/y s.t. pred >= y, coefficients >= 0.
    Solved as the dual: max sum y_i l_i s.t. sum_i a_ij l_i <= c_j, l >= 0; the primal is the duals. With
    per_frame, one more coefficient paid once per frame holding a message (folded into c_f)."""
    feats = (["frame"] if per_frame else []) + ["p0"] + KINDS
    rows = [(f, y) for f, y in frames if y > 0]
    c = [sum(f.get(k, 0) / y for f, y in rows) for k in feats]
    # dual: variables l_i (one per frame), constraints one per feature j: sum_i a_ij l_i <= c_j
    A = [[f.get(k, 0) for f, y in rows] for k in feats]
    keep = [j for j in range(len(feats)) if c[j] > 0]
    A2 = [A[j] for j in keep]
    b2 = [c[j] for j in keep]
    obj = [y for f, y in rows]
    _, _, duals = simplex(obj, A2, b2)
    w = {k: 0.0 for k in feats}
    for idx, j in enumerate(keep):
        w[feats[j]] = duals[idx]
    return w


def features(hist):
    f = {"p0": 0, "frame": 1}
    for counts, mult in hist:
        f["p0"] += mult
        for k, v in counts.items():
            f[k] = f.get(k, 0) + v * mult
    return f


def pred(f, w):
    return sum(w.get(k, 0) * v for k, v in f.items())


FEATS_ALL = ["frame", "p0"] + KINDS
STATE = {}


def main():
    dec = parse_decode()
    tag = parse_tag()
    D = {key: agg(dec, key) for key in ("Fe", "Fe4", "D", "G")}
    T = agg(tag)
    meta = dec["native"][0] if dec["native"] else dec["interpreted"][0]
    out = []
    p = out.append
    p("# derive.out: generated by derive.py from decode_cost.out and tag_cost.out")
    p("")
    for mode in MODES:
        if not dec[mode]:
            continue
        t = T[mode]
        # ---- claim 2: prices
        p(f"## {mode}: claim 2, frame and byte prices (ns), median of the run medians (7 native, 3 interpreted) [highest run median]")
        def tv(k):
            return t[k][0], t[k][1]
        rel = {}
        for k in t:
            m = re.match(r"TAG lane=r kind=(\w+) B=(\d+) pos=(\S+) hashes=(\d)", k)
            if m:
                rel[(m.group(1), int(m.group(2)), m.group(3))] = t[k]
        unr = {}
        for k in t:
            m = re.match(r"TAG lane=u kind=(\w+) B=(\d+) pos=(\S+) hashes=(\d)", k)
            if m:
                unr[(int(m.group(2)), m.group(3))] = t[k]
        positions = ["e+0", "e+1", "e+2", "e+3", "e+4", "fail"]
        p("reliable, header-only (3 B) by position: " + ", ".join(f"{q} {rel[('string', 3, q)][0]:.0f} [{rel[('string', 3, q)][1]:.0f}]" for q in positions))
        cfr = max(rel[("string", 3, q)][0] for q in positions)
        cfr_worst = max(rel[("string", 3, q)][1] for q in positions)
        u1 = math.ceil((P0_DESIGN + P1_DESIGN) / UNIT) * UNIT  # one 1-leaf element at the design rule
        # c_b from frames of 1,000 B or more (smaller frames are c_f and their element; the whole-frame check below
        # and gate.luau cover them)
        cbr, cbr_worst, cbr_at = 0.0, 0.0, None
        for (kind, b, q), v in rel.items():
            if b < 1000:
                continue
            el = 0.0 if q == "fail" else u1
            if (v[0] - cfr - el) / (b - 3) > cbr:
                cbr, cbr_at = (v[0] - cfr - el) / (b - 3), (kind, b, q)
            cbr_worst = max(cbr_worst, (v[1] - cfr_worst - el) / (b - 3))
        p(f"c_f,r = {cfr:.0f} ns [{cfr_worst:.0f}] (header-only frame at its costliest position)")
        p(f"c_b,r set by {cbr_at}")
        for kind in ("string", "buffer"):
            for b in sorted({k[1] for k in rel if k[0] == kind}):
                if b <= 3:
                    continue
                p(f"  {kind} B={b}: " + ", ".join(f"{q} {rel[(kind, b, q)][0]:.0f}" for q in positions))
        uh = [unr[(4, q)] for q in ("c1", "c2", "c3", "fail")]
        cfu = max(v[0] for v in uh)
        cfu_worst = max(v[1] for v in uh)
        p("unreliable, header-only (4 B): " + ", ".join(f"{q} {unr[(4, q)][0]:.0f} [{unr[(4, q)][1]:.0f}]" for q in ("c1", "c2", "c3", "fail")))
        cbu, cbu_worst, cbu_at = 0.0, 0.0, None
        for (b, q), v in unr.items():
            if b < 250:
                continue
            el = u1 if q in ("c1", "c3") else 0.0
            if (v[0] - cfu - el) / (b - 4) > cbu:
                cbu, cbu_at = (v[0] - cfu - el) / (b - 4), (b, q)
            cbu_worst = max(cbu_worst, (v[1] - cfu_worst - el) / (b - 4))
        p(f"c_b,u set by {cbu_at}")
        for b in sorted({k[0] for k in unr if k[0] > 4}):
            p(f"  string B={b}: " + ", ".join(f"{q} {unr[(b, q)][0]:.0f}" for q in ("c1", "c2", "c3", "fail")))
        walk = {}
        for k in t:
            m = re.match(r"WALK alone entries=(\d+)", k)
            if m:
                walk[int(m.group(1))] = t[k]
        wslope = (walk[16384][0] - walk[0][0]) / 16384
        wslope_worst = (walk[16384][1] - walk[0][0]) / 16384
        p(f"instance-list walk (instanceCountOf alone): {wslope:.2f} ns per entry [{wslope_worst:.2f}] = {wslope / 8:.3f} ns per byte of charge")
        for kk in sorted(k for k in t if k.startswith("WALK refused")):
            p(f"  {kk}: {t[kk][0]:.0f}")
        p(f"c_b,r = {cbr:.2f} ns/B [{cbr_worst:.2f}] before the walk; with the walk {cbr + wslope / 8:.2f} [{cbr_worst + wslope_worst / 8:.2f}]")
        p(f"c_f,u = {cfu:.0f} ns [{cfu_worst:.0f}]")
        p(f"c_b,u = {cbu:.2f} ns/B [{cbu_worst:.2f}] before the walk; with the walk {cbu + wslope / 8:.2f} [{cbu_worst + wslope_worst / 8:.2f}]")
        CF_R, CB_R = cfr, cbr + wslope / 8
        CF_U, CB_U = cfu, cbu + wslope / 8
        CF_Rw, CB_Rw = cfr_worst, cbr_worst + wslope_worst / 8
        p("HELLO rows:")
        for kk in sorted(k for k in t if k.startswith("HELLO")):
            m = re.search(r"rows=(\d+) B=(\d+)", kk)
            rows, b = int(m.group(1)), int(m.group(2))
            v = t[kk][0]
            hello_units = rows * math.ceil((P0_DESIGN + P1_DESIGN * 5) / UNIT)
            bound = CF_R + CB_R * b + UNIT * hello_units
            p(f"  {kk}: {v:.0f} ns, {v / rows:.0f} per row; bound c_f,r + c_b,r B + 100 ns x {hello_units} units (L = 5 per row) = {bound:.0f}: ratio {v / bound:.2f}")
        p("")

        # ---- claim 1: per-frame excess and the unit price
        fe4, dd, gg, fe = D["Fe4"][mode], D["D"][mode], D["G"][mode], D["Fe"][mode]
        names = sorted(fe4)
        frames_m, frames_g = [], []
        p(f"## {mode}: claim 1, per frame (ns): excess = F_e4 - c_f,r - c_b,r B; units at the design rule (p_0 2,000, p_1 133, weights of §7.5)")
        p(f"{'case':28s} {'B':>6s} {'el':>5s} {'Fe':>9s} {'Fe4':>9s} {'D':>9s} {'G':>9s} {'excess':>9s} {'units':>7s} {'ratio':>6s} {'worst':>6s} {'gen':>6s}")
        worst = []
        for n in names:
            r = meta.get(n)
            if r is None:
                continue
            B = r["B"]
            hist = r["sig"]
            units = units_of(hist, DESIGN_W, P0_DESIGN, P1_DESIGN)
            ex = fe4[n][0] - CF_R - CB_R * B
            exw = fe4[n][1] - CF_R - CB_R * B
            gen_ex = fe4[n][0] - dd[n][0] + gg[n][0] - CF_R - CB_R * B
            cap = UNIT * units
            ratio = ex / cap if cap > 0 else (float("inf") if ex > 0 else 0.0)
            ratio_w = exw / cap if cap > 0 else (float("inf") if exw > 0 else 0.0)
            ratio_g = gen_ex / cap if cap > 0 else (float("inf") if gen_ex > 0 else 0.0)
            worst.append((ratio, ratio_w, ratio_g, n))
            p(f"{n:28s} {B:6d} {r['el']:5d} {fe[n][0]:9.0f} {fe4[n][0]:9.0f} {dd[n][0]:9.0f} {gg[n][0]:9.0f} {ex:9.0f} {units:7d} {ratio:6.2f} {ratio_w:6.2f} {ratio_g:6.2f}")
            if hist:
                frames_m.append((features(hist), ex))
                frames_g.append((features(hist), gen_ex))
        worst.sort(reverse=True)
        p("")
        p("highest ratios (excess / (100 ns x units)), milestone [worst run] (generated):")
        for ratio, ratio_w, ratio_g, n in worst[:15]:
            p(f"  {n:28s} {ratio:6.2f} [{ratio_w:6.2f}] ({ratio_g:6.2f})")
        over = [n for ratio, _, _, n in worst if ratio > 1]
        over_g = [n for _, _, ratio_g, n in worst if ratio_g > 1]
        p(f"frames over the design rule's unit price: milestone {len(over)} of {len(worst)}, generated {len(over_g)} of {len(worst)}")
        p("")

        # ---- claim 1: marginal cost per field, from records of 16 and 1 fields of each kind, at e (1 hash)
        h1 = (rel[("string", 15906, "fail")][0] - rel[("string", 3, "fail")][0]) / (15906 - 3) / 5
        he = fe["header only"][0]
        p(f"## {mode}: claim 1, marginal ns per field per message = ((F_e - h B) / msgs at 16 fields - (F_e - h B) / msgs at 1 field) / 15,")
        p(f"   h = {h1:.2f} ns/B (one hash per byte, from failing frames); per-message base = (F_e - header-only F_e - h (B - 3)) / msgs of the no-payload event")
        forms = ("row1", "runs", "colC", "colR")
        MARG = {}
        BASE = {}
        BASE1 = {}
        for path in ("milestone", "generated"):
            def val(n):
                v = fe[n][0]
                if path == "generated":
                    v = v - dd[n][0] + gg[n][0]
                return v
            p(f"  {path}:")
            base = {}
            for f_ in forms:
                n = "none " + f_
                r = meta[n]
                base[f_] = (val(n) - he - h1 * (r["B"] - 3)) / r["msgs"]
            p("    no-payload message: " + ", ".join(f"{f_} {base[f_]:.0f}" for f_ in forms))
            BASE[path] = base
            kinds = []
            for n in meta:
                m = re.match(r"(\w+)_16 row1$", n)
                if m:
                    kinds.append(m.group(1))
            for k in sorted(kinds):
                cells = []
                for f_ in forms:
                    a, b = meta[f"{k}_16 {f_}"], meta[f"{k}_1 {f_}"]
                    ya = (val(f"{k}_16 {f_}") - h1 * a["B"]) / a["msgs"]
                    yb = (val(f"{k}_1 {f_}") - h1 * b["B"]) / b["msgs"]
                    cells.append((ya - yb) / 15)
                MARG[(path, k)] = dict(zip(forms, cells))
                # the per-message base of a message with data: the 1-field record less its one field
                for f_, c in zip(forms, cells):
                    b = meta[f"{k}_1 {f_}"]
                    yb1 = (val(f"{k}_1 {f_}") - he - h1 * (b["B"] - 3)) / b["msgs"]
                    BASE1[(path, k, f_)] = yb1 - c
                p(f"    {k:12s} " + " ".join(f"{f_} {c:6.0f}" for f_, c in zip(forms, cells)) + f"   max {max(cells):6.0f} ns = {max(cells) / P1_DESIGN:4.1f} x 133")
        p("")

        # ---- claim 1: fit
        fits = {}
        for per_frame in (False, True):
            for label, frames in (("milestone", frames_m), ("generated", frames_g)):
                w = upper_fit(frames, per_frame)
                form = "variant B, with a per-frame term (folded into c_f)" if per_frame else "variant A, the §7.5 form"
                p(f"## {mode}: claim 1, upper fit p(shape) = p_0 + sum w_k n_k ns per element, {label} decoder, {form}")
                p(("  per frame %.0f ns; " % w.get("frame", 0) if per_frame else "  ") + "p_0 = %.0f ns; " % w["p0"] + ", ".join(f"{k} {w[k]:.0f}" for k in KINDS))
                ratios = sorted((y / pred(f, w), y, pred(f, w)) for f, y in frames if y > 0)
                p(f"  frames {len(frames)}; measured / predicted: min {ratios[0][0]:.2f}, median {statistics.median([r[0] for r in ratios]):.2f}, max {ratios[-1][0]:.3f}")
                p(f"  frames within 2% of the fit (the binding ones): {sum(1 for r in ratios if r[0] > 0.98)}")
                fits[(per_frame, label)] = w
        p("")

        if mode != "native":
            # the native unit rule (variant M) priced at this mode's own c_f, c_b: the unit price it needs
            wmw, p0m, _ = STATE["RULE_M"]
            need = []
            for n in names:
                r = meta.get(n)
                if r is None or not r["sig"]:
                    continue
                units = units_of(r["sig"], wmw, p0m, P1_DESIGN)
                need.append(((fe4[n][0] - CF_R - CB_R * r["B"]) / units, n))
                need.append(((fe4[n][0] - dd[n][0] + gg[n][0] - CF_R - CB_R * r["B"]) / units, n + " (generated)"))
            need.sort(reverse=True)
            p(f"## {mode}: the native unit rule (variant M) at this mode's c_f,r {CF_R:.0f} ns, c_b,r {CB_R:.2f} ns/B: unit price needed (ns per unit)")
            for v, n in need[:8]:
                p(f"    {n:40s} {v:7.0f}")
            p(f"  max {need[0][0]:.0f} ns per unit = {need[0][0] / UNIT:.2f} x the native 100 ns")
            p("")
            continue

        def rule_from(per_frame):
            fit = {k: max(fits[(per_frame, "milestone")].get(k, 0), fits[(per_frame, "generated")].get(k, 0)) for k in FEATS_ALL}
            if per_frame:
                p0n = math.ceil(fit["p0"] / 100) * 100
            else:
                p0n = max(P0_DESIGN, math.ceil(fit["p0"] / 100) * 100)
            dcf = math.ceil(fit["frame"] / 100) * 100
            neww = {k: max(DESIGN_W[k], math.ceil(fit[k] / P1_DESIGN - 1e-9)) for k in KINDS}
            return neww, p0n, dcf

        def check(neww, p0n, dcf):
            rs = []
            for n in names:
                r = meta.get(n)
                if r is None:
                    continue
                units = units_of(r["sig"], neww, p0n, P1_DESIGN)
                bound = CF_R + (dcf if r["sig"] else 0) + CB_R * r["B"] + UNIT * units
                rs.append((fe4[n][0] / bound, fe4[n][1] / bound, (fe4[n][0] - dd[n][0] + gg[n][0]) / bound, n, units))
            rs.sort(reverse=True)
            return rs

        # variant M: weights from the marginal per-field costs (max over forms and over both decoders), p_0 from the
        # per-message base of the no-payload event (max over forms and decoders)
        def mmax(*terms):
            # each term: (sign, kind); the value per form and path is the signed sum; returns the max over forms, paths
            best = -1e18
            for path in ("milestone", "generated"):
                for f_ in forms:
                    v = sum(sign * MARG[(path, k)][f_] for sign, k in terms)
                    best = max(best, v)
            return best
        wm = {
            "bool": mmax((1, "bool")), "int": max(mmax((1, "int8")), mmax((1, "int32"))), "varint": mmax((1, "varint")),
            "number": mmax((1, "number")), "f32": mmax((1, "f32")), "f64": mmax((1, "f64")), "angle": mmax((1, "angle")),
            "enum": mmax((1, "enum3")), "string": max(mmax((1, "str8")), mmax((1, "str200"))),
            "buffer": max(mmax((1, "buf8")), mmax((1, "buf200"))), "robloxEnum": mmax((1, "robloxEnum")),
            "instance": mmax((1, "instance")), "vector3": mmax((1, "vector3")), "vector3f32": mmax((1, "vector3f32")),
            "color3": mmax((1, "color3")), "direction": mmax((1, "direction")), "rotation": mmax((1, "rotation")),
            "cframe": mmax((1, "cframe")),
            "optional": max(mmax((1, "optAbsent")), mmax((1, "optPresent"), (-1, "int8")), mmax((1, "optRecord"), (-1, "record1"))),
            "union": mmax((1, "union2"), (-1, "int8")),
            "record": max(mmax((1, "record1"), (-1, "int8")), mmax((1, "recordDeep4"), (-1, "int8")) / 4),
            "array": mmax((1, "arr0")), "map": mmax((1, "map0")),
        }
        nested_base = max(mmax((1, "arr1"), (-1, "arr0"), (-1, "int8")), mmax((1, "map1"), (-1, "map0"), (-1, "int8"), (-1, "bool")))
        base_none = max(max(BASE[path].values()) for path in BASE)
        base1_at = max(BASE1, key=lambda key: BASE1[key])
        base_max = max(base_none, BASE1[base1_at])
        p(f"  per-message base: no-payload event {base_none:.0f} ns; a message with data (1-field record less its field), highest {BASE1[base1_at]:.0f} ns at {base1_at}")
        for f_ in forms:
            vals = sorted(BASE1[(path, k, ff)] for (path, k, ff) in BASE1 if ff == f_ and path == "milestone")
            p(f"    {f_}: milestone per-message base with data, median over kinds {statistics.median(vals):.0f}, max {vals[-1]:.0f} ns")
        p("## native: claim 1, the per-leaf cost model from the marginal costs (variant M): ns per node, max over the four forms and both decoders")
        p("  " + ", ".join(f"{k} {wm[k]:.0f}" for k in KINDS))
        p(f"  per nested element base (array element, map pair) {nested_base:.0f} ns")
        p0m = math.ceil(base_max / 100) * 100
        wmw = {k: max(1 if DESIGN_W[k] > 0 else 0, math.ceil(wm[k] / P1_DESIGN - 1e-9)) for k in KINDS}
        p(f"  as a unit rule: p_0 = {p0m} ns (base rounded up), p_1 = 133 ns, weight = ceil(ns / 133), at least 1 where §7.5 has one:")
        p("  weights (leaves): " + ", ".join(f"{k} {wmw[k]}" for k in KINDS))
        p("  against §7.5: " + ", ".join(f"{k} {DESIGN_W[k]} -> {wmw[k]}" for k in KINDS if wmw[k] != DESIGN_W[k]))
        rs = check(wmw, p0m, 0)
        p("  highest F_e4 / bound (whole frame, mu = 0), milestone [worst run] (generated):")
        for a, b2, c2, n, u in rs[:15]:
            p(f"    {n:28s} {a:6.3f} [{b2:6.3f}] ({c2:6.3f})  units {u}")
        p(f"  max over {len(rs)} frames: median-run {max(r[0] for r in rs):.3f}, worst-run {max(r[1] for r in rs):.3f}, generated {max(r[2] for r in rs):.3f}")
        for mu in (0.0, 0.10, 0.25):
            p(f"  frames over (1 + {mu:.2f}) x bound: median-run {sum(1 for r in rs if r[0] > 1 + mu)}, worst-run {sum(1 for r in rs if r[1] > 1 + mu)}")
        p("")

        rules = {}
        rules["M"] = (wmw, p0m, 0)

        STATE["RULE_M"] = (wmw, p0m, 0)
        for per_frame in (False, True):
            neww, p0n, dcf = rule_from(per_frame)
            rules[per_frame] = (neww, p0n, dcf)
            name = "B (a per-frame term added to c_f)" if per_frame else "A (§7.5's form)"
            p(f"## native: claim 1, a unit rule that holds, variant {name}: p_0 = fit rounded up to 100 ns"
              + ("" if per_frame else " (at least 2,000)") + ", each weight = max(§7.5's, ceil(fit / 133 ns)), the fit the larger of the milestone's and the generated decoder's")
            raised = ", ".join(f"{k} {DESIGN_W[k]} -> {neww[k]}" for k in KINDS if neww[k] != DESIGN_W[k])
            p(f"  p_0 = {p0n:.0f} ns, p_1 = 133 ns" + (f", c_f + {dcf:.0f} ns per frame holding a message" if per_frame else "") + f"; weights raised over §7.5: {raised}")
            p("  weights (leaves): " + ", ".join(f"{k} {neww[k]}" for k in KINDS))
            rs = check(neww, p0n, dcf)
            p("  highest F_e4 / bound (whole frame, mu = 0), milestone [worst run] (generated):")
            for a, b2, c2, n, u in rs[:12]:
                p(f"    {n:28s} {a:6.3f} [{b2:6.3f}] ({c2:6.3f})  units {u}")
            p(f"  max over {len(rs)} frames: median-run {max(r[0] for r in rs):.3f}, worst-run {max(r[1] for r in rs):.3f}, generated {max(r[2] for r in rs):.3f}")
            for mu in (0.0, 0.10, 0.25):
                p(f"  frames over (1 + {mu:.2f}) x bound: median-run {sum(1 for r in rs if r[0] > 1 + mu)}, worst-run {sum(1 for r in rs if r[1] > 1 + mu)}")
            p("")
        rsd = check(DESIGN_W, P0_DESIGN, 0)
        p("## native: claim 1, the rule as §7.5 states it (p_0 2,000, its weights), whole frame F_e4 / bound at the measured c_f, c_b:")
        for a, b2, c2, n, u in rsd[:12]:
            p(f"    {n:28s} {a:6.3f} [{b2:6.3f}] ({c2:6.3f})  units {u}")
        p(f"  frames over the bound: median-run {sum(1 for r in rsd if r[0] > 1)} of {len(rsd)}; over 1.25 x: {sum(1 for r in rsd if r[0] > 1.25)}")
        p("")

        # ---- claim 3: the bound and the defaults
        p("## native: claim 3, the bound per player and second")
        move6 = [({"int": 3, "bool": 1, "number": 1, "enum": 1}, 1)]
        sm = [({"enum": 1, "string": 1, "int": 1, "optional": 1}, 1)]
        p(f"prices: c_f,r {CF_R:.0f} ns, c_f,u {CF_U:.0f} ns, c_b,r {CB_R:.2f} ns/B, c_b,u {CB_U:.2f} ns/B (walk included), 100 ns per unit")
        Fr, Fu, Br, Bu, E = 60, 120, 8192, 16384, 10000
        bytes_cost = CB_R * Br + CB_U * Bu
        worst_unit = max(r[0] for r in worst)
        frames0 = CF_R * Fr + CF_U * Fu
        p(f"current defaults (Fr {Fr}, Fu {Fu}, Br {Br}, Bu {Bu}, E {E} units/s, §7.5's rule): frames {frames0 / 1000:.0f} us + bytes {bytes_cost / 1000:.0f} us + units {UNIT * E / 1000:.0f} us = {(frames0 + bytes_cost + UNIT * E) / 1000:.0f} us/s at mu = 0 if 100 ns per unit held;")
        p(f"  at §7.5's weights the measured worst excess is {worst_unit:.2f} x 100 ns per unit: units {worst_unit * UNIT * E / 1000:.0f} us, total {(frames0 + bytes_cost + worst_unit * UNIT * E) / 1000:.0f} us/s")
        for per_frame in ("M", False, True):
            neww, p0n, dcf = rules[per_frame]
            busy = 60 * units_of(move6, neww, p0n, P1_DESIGN) + 10 * units_of(sm, neww, p0n, P1_DESIGN)
            busy_design = 60 * units_of(move6, DESIGN_W, P0_DESIGN, P1_DESIGN) + 10 * units_of(sm, DESIGN_W, P0_DESIGN, P1_DESIGN)
            cfr, cfu = CF_R + dcf, CF_U + dcf
            frames_cost = cfr * Fr + cfu * Fu
            name = "M" if per_frame == "M" else ("B" if per_frame else "A")
            p(f"variant {name}: c_f,r {cfr:.0f}, c_f,u {cfu:.0f} ns; units at p_0 {p0n:.0f}; busy model {busy} units/s ({busy_design} at §7.5's rule): move6 {units_of(move6, neww, p0n, P1_DESIGN)}, sm {units_of(sm, neww, p0n, P1_DESIGN)} units")
            p(f"  at the current defaults: frames {frames_cost / 1000:.0f} + bytes {bytes_cost / 1000:.0f} + units {UNIT * E / 1000:.0f} = {(frames_cost + bytes_cost + UNIT * E) / 1000:.0f} us/s at mu = 0")
            burst_cost = cfr * 240 + cfu * 240 + CB_R * 49152 + CB_U * 32768 + UNIT * 81920
            for mu in (0.0, 0.10, 0.25):
                target = 2_000_000 / (1 + mu)
                e_units = math.floor((target - frames_cost - bytes_cost) / UNIT / 1000) * 1000
                total = (1 + mu) * (frames_cost + bytes_cost + UNIT * e_units)
                p(f"  mu = {mu:.2f}: inbound.elements.perSecond = floor(({target / 1000:.0f} - {frames_cost / 1000:.0f} - {bytes_cost / 1000:.0f}) us / 100 ns) to 1,000 = {e_units} units/s "
                  f"({e_units / busy:.1f}x the busy model); bound (1 + mu)(frames + bytes + units) = {total / 1000:.0f} us/s; full refill (240, 240, 49,152, 32,768, 81,920) {(1 + mu) * burst_cost / 1e6:.2f} ms")
        p("")
    print("\n".join(out))


if __name__ == "__main__":
    main()
