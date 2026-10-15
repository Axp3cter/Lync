"""Bytecode size of codecs woven into game scripts against one shared client shard.

Re-derives client-security-build §3.2's 5.0x (50 sites of one definition, full encoder inlined at each) and
measures realistic shapes: 20 definitions of the five gen.py shapes, s sites per definition, each site in its own
script ("spread") or all sites of a definition in one script ("clustered").

Forms, each = client shard + every game script, minus the same scripts with no call site:
  U    unwoven: sites call Net.def:fire({...}); full shard
  W2   inline at each site (one line, line-preserving); full shard kept as the type module and fallback
  W2r  as W2, with the closed definitions' generic encoders dropped from the built shard
  W1t  one helper per definition per script, in a table (not inlined, so error lines hold); full shard
  W3   sites call the shard's scalar entry Internal.def(a, b, ...); full shard (no duplication)

Usage: python3 -I size.py LUAU_COMPILE WORKDIR > size.out
"""
import os, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen

LC, WORK = sys.argv[1], sys.argv[2]
os.makedirs(WORK, exist_ok=True)

def compile_size(src, g):
    path = os.path.join(WORK, "m.luau")
    open(path, "w").write(src)
    r = subprocess.run([LC, "--binary", "-O2", f"-g{g}", path], capture_output=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.decode() + r.stdout.decode()[:500])
    return len(r.stdout)

SHAPES = ["strike", "move6", "chat", "buy", "announce"]
BASE = dict(gen.DEFS)

def setup(ndefs):
    names = [f"{SHAPES[k % 5]}_{k}" for k in range(ndefs)]
    gen.DEFS = {n: BASE[n.rsplit("_", 1)[0]] for n in names}
    gen.IDS = {n: i for i, n in enumerate(sorted(gen.DEFS))}
    gen.ID_BITS = gen.bits_for(len(gen.DEFS))
    gen.SITE_ARGS = {n: gen_args(n.rsplit("_", 1)[0]) for n in names if n.rsplit("_", 1)[0] in ("strike", "move6", "chat")}
    gen.LITERAL_SITES = {n: LIT[n.rsplit("_", 1)[0]] for n in names if n.rsplit("_", 1)[0] in LIT}
    gen.ENUMS.clear()
    return names

LIT = {"buy": {"item": "sword"}, "announce": {"kind": "round", "number": 3}}
def gen_args(shape):
    return {"strike": {"target": "x.id", "aim": "x.dir"},
            "move6": {"a": "x.a", "b": "x.b", "c": "x.c", "d": "x.d", "e": "x.e", "f": "x.f"},
            "chat": {"": "x.text"}}[shape]

def site_code(name, form):
    shape = name.rsplit("_", 1)[0]
    literal = name in gen.LITERAL_SITES
    if form == "U":
        return f"Net.{name}:fire({gen.table_expr(name)})"
    codec = gen.DEFS[name]
    paths = [] if literal else gen.leaf_paths(codec)
    args = [gen.SITE_ARGS[name][p] for p in paths]
    if form == "W3" and not literal:
        return f"Internal.{name}({', '.join(args)})"
    if form in ("W2", "W2r") or (form == "W3" and literal):
        if literal:
            fn = gen.woven_body(name, literal=True)
            return "do " + " ".join(fn) + " end"
        params = [f"a{i}" for i in range(len(paths))]
        fn = gen.woven_body(name, dict(zip(paths, params)))
        return f"do local {', '.join(params)} = {', '.join(args)} " + " ".join(fn) + " end"
    if form == "W1t":
        return f"__lync.{name}({', '.join(args)})"
    raise ValueError(form)

def helper(name):
    literal = name in gen.LITERAL_SITES
    codec = gen.DEFS[name]
    if literal:
        return f"function __lync.{name}() " + " ".join(gen.woven_body(name, literal=True)) + " end"
    paths = gen.leaf_paths(codec)
    params = [f"a{i}" for i in range(len(paths))]
    return f"function __lync.{name}({', '.join(params)}) " + " ".join(gen.woven_body(name, dict(zip(paths, params)))) + " end"

def script(sites, form, with_sites=True):
    """sites: list of (definition, index). One game function per site."""
    head = ["--!optimize 2", "local Net = Net"]
    lits_only = all(d in gen.LITERAL_SITES for d, _ in sites)
    if (form in ("W2", "W2r", "W1t") or (form == "W3" and lits_only)) and with_sites:
        head.append(gen.RT_IMPORTS)
        head += gen.enum_decls()
    if form == "W3" and with_sites:
        head.append("local Internal = Net.__internal")
    if form == "W1t" and with_sites:
        head.append("local __lync = {}")
        for d in sorted({d for d, _ in sites}):
            head.append(helper(d))
    body = ["local M = {}"]
    for d, k in sites:
        inner = site_code(d, form) if with_sites else ""
        body.append(f"function M.on_{d}_{k}(x) {inner} end")
    return "\n".join(head + body + ["return M"]) + "\n"

def shard_src(drop=()):
    keep = {n: c for n, c in gen.DEFS.items() if n not in drop}
    saved = gen.DEFS
    gen.DEFS = keep
    gen.ENUMS.clear()
    src = gen.shard()
    gen.DEFS = saved
    return src

def measure(ndefs, s, placement, form, g):
    names = setup(ndefs)
    # build scripts
    if placement == "spread":
        scripts = [[(d, k)] for d in names for k in range(s)]
    else:
        scripts = [[(d, k) for k in range(s)] for d in names]
    total = 0
    for sc in scripts:
        gen.ENUMS.clear()
        for d, _ in sc:  # register enums used by this script
            gen.woven_body(d, literal=d in gen.LITERAL_SITES) if d in gen.LITERAL_SITES else gen.woven_body(d, {p: "z" for p in gen.leaf_paths(gen.DEFS[d])})
        total += compile_size(script(sc, form), g) - compile_size(script(sc, form, with_sites=False), g)
    sh = compile_size(shard_src(drop=names if form == "W2r" else ()), g)
    return total, sh

print("## re-derivation of the 5.0x (client-security-build placement/size.py), luau-compile -O2")
print("see size_orig.out")
print()
print("| defs | sites/def | placement | -g | form | site bytes | shard bytes | total | vs U |")
print("|---|---|---|---|---|---|---|---|---|")
for ndefs, s, placement in [(20, 1, "spread"), (20, 2, "spread"), (20, 3, "spread"), (20, 5, "spread"),
                            (20, 3, "clustered"), (20, 10, "spread"), (1, 50, "spread"), (5, 50, "clustered")]:
    for g in (0, 1):
        base = None
        for form in ("U", "W3", "W1t", "W2", "W2r"):
            sites_b, shard_b = measure(ndefs, s, placement, form, g)
            tot = sites_b + shard_b
            if form == "U":
                base = tot
            print(f"| {ndefs} | {s} | {placement} | {g} | {form} | {sites_b} | {shard_b} | {tot} | {tot / base:.2f} |")
        sys.stdout.flush()
