"""Prototype weaver: rewrites call sites of a client shard in a place's scripts (dumped by place_io.luau) into
inline encoders, line for line, and reports which definitions are closed (every reference woven).

Never touches the developer's files: input and output are JSON dumps of a built place.

Usage: python3 -I weave.py LUAU_AST IN.json OUT.json REPORT.json SHARD_PATH
  SHARD_PATH: instance path of the client shard module, e.g. ReplicatedStorage.Shared.Net.client

Resolution (sound against the developer's code, never against a modified client):
  - a shard binding is a local initialised by require(E) where E resolves statically to SHARD_PATH, through
    game:GetService("X"), .Name, :WaitForChild("Name"), :FindFirstChild("Name"), script, .Parent, or a local
    bound to one of those; a definition alias is a local initialised by binding.def; neither may be reassigned;
  - a woven site is a call statement binding.def:fire(ARG) or alias:fire(ARG) (also dot calls, as roblox-ts
    emits) whose ARG is a table constructor with exactly the record's field names as constant keys (or, for a
    non-record codec, any single expression);
  - every other use of a binding (passed, returned, stored, indexed by a non-constant, iterated, reassigned)
    makes the namespace incomplete: nothing is closed, sites are still woven (weaving never needs completeness);
  - a definition is closed when the namespace is complete and every occurrence of its name as an index
    (anything.def) or a constant string anywhere in the scanned scripts is part of a woven site.
"""
import json, os, re, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen

LUAU_AST, IN, OUT, REPORT, SHARD = sys.argv[1:6]
VERBS = {"fire"}

def parse(src):
    with tempfile.NamedTemporaryFile("w", suffix=".luau", delete=False) as f:
        f.write(src)
        p = f.name
    try:
        r = subprocess.run([LUAU_AST, p], capture_output=True, text=True)
        if r.returncode != 0:
            return None
        return json.loads(r.stdout)
    finally:
        os.unlink(p)

def loc(s):
    a, b = s.split(" - ")
    l1, c1 = map(int, a.split(","))
    l2, c2 = map(int, b.split(","))
    return l1, c1, l2, c2

def walk(node, parent=None, key=None, out=None):
    if out is None:
        out = []
    if isinstance(node, dict):
        if "type" in node:
            out.append((node, parent, key))
            parent_next = node
        else:
            parent_next = parent
        for k, v in node.items():
            if k in ("local",):  # AstLocal reference, not a child
                continue
            if isinstance(v, (dict, list)):
                walk(v, parent_next, k, out)
    elif isinstance(node, list):
        for v in node:
            walk(v, parent, key, out)
    return out

def local_id(l):
    return (l["name"], l["location"])

def resolve_instance(expr, env, script_path):
    """Static instance path of an expression, or None."""
    t = expr["type"]
    if t == "AstExprGlobal" and expr["global"] == "script":
        return script_path
    if t == "AstExprGlobal" and expr["global"] == "game":
        return ""
    if t == "AstExprLocal":
        return env.get(local_id(expr["local"]))
    if t == "AstExprIndexName" and expr["op"] == ".":
        base = resolve_instance(expr["expr"], env, script_path)
        if base is None:
            return None
        if expr["index"] == "Parent":
            return base.rsplit(".", 1)[0] if "." in base else ""
        return (base + "." if base else "") + expr["index"]
    if t == "AstExprCall" and expr["func"]["type"] == "AstExprIndexName" and expr["func"]["op"] == ":":
        m = expr["func"]["index"]
        args = expr["args"]
        if m in ("GetService", "WaitForChild", "FindFirstChild") and args and args[0]["type"] == "AstExprConstantString":
            base = resolve_instance(expr["func"]["expr"], env, script_path)
            if base is None:
                return None
            return (base + "." if base else "") + args[0]["value"]
    return None

def text_span(lines, l1, c1, l2, c2):
    if l1 == l2:
        return lines[l1][c1:c2]
    parts = [lines[l1][c1:]] + lines[l1 + 1:l2] + [lines[l2][:c2]]
    return "\n".join(parts)

def analyse(script, report):
    src = script["source"]
    ast = parse(src)
    if ast is None:
        report["unparsed"].append(script["path"])
        return None, []
    nodes = walk(ast["root"])
    parents = {id(n): (p, k) for n, p, k in nodes}
    env, bindings, aliases, reassigned = {}, set(), {}, set()
    # pass 1: instance locals, shard bindings, definition aliases
    for n, p, k in nodes:
        if n["type"] == "AstStatLocal" and len(n["vars"]) == len(n["values"]):
            for v, e in zip(n["vars"], n["values"]):
                lid = local_id(v)
                inst = resolve_instance(e, env, script["path"])
                if inst is not None:
                    env[lid] = inst
                if e["type"] == "AstExprCall" and e["func"]["type"] == "AstExprGlobal" and e["func"]["global"] == "require" and len(e["args"]) == 1:
                    if resolve_instance(e["args"][0], env, script["path"]) == SHARD:
                        bindings.add(lid)
                        report["bindingStatements"].setdefault(script["path"], []).append(n["location"])
                if e["type"] == "AstExprIndexName" and e["op"] == "." and e["expr"]["type"] == "AstExprLocal" and local_id(e["expr"]["local"]) in bindings and e["index"] in gen.DEFS:
                    aliases[lid] = e["index"]
        if n["type"] == "AstStatAssign":
            for v in n["vars"]:
                if v["type"] == "AstExprLocal":
                    reassigned.add(local_id(v["local"]))
    if reassigned & (bindings | set(aliases)):
        report["escapes"].append({"script": script["path"], "why": "binding reassigned"})
    sites, accounted = [], set()
    # pass 2: classify every use of a binding or alias
    for n, p, k in nodes:
        if n["type"] != "AstExprLocal":
            continue
        lid = local_id(n["local"])
        if lid not in bindings and lid not in aliases:
            continue
        line = loc(n["location"])[0] + 1
        if lid in aliases:
            dname, idx = aliases[lid], n
        else:
            if p is None or p["type"] != "AstExprIndexName" or p["op"] != "." or p["index"] not in gen.DEFS:
                # a use that is not binding.def: passed, returned, stored, iterated or indexed otherwise
                report["escapes"].append({"script": script["path"], "line": line, "why": f"binding used as {p['type'] if p else 'root'}"})
                continue
            dname, idx = p["index"], p
        pp, kk = parents.get(id(idx), (None, None))
        if pp is not None and pp["type"] == "AstStatLocal" and lid in bindings:
            continue  # the alias declaration itself (tracked through the alias's own uses)
        call, ck = parents.get(id(pp), (None, None)) if pp else (None, None)
        if not (pp and pp["type"] == "AstExprIndexName" and pp["index"] in VERBS and call and call["type"] == "AstExprCall" and call["func"] is pp):
            report["unwoven"].append({"script": script["path"], "line": line, "definition": dname, "why": "not a fire call"})
            continue
        stmt, sk = parents.get(id(call), (None, None))
        if not (stmt and stmt["type"] == "AstStatExpr"):
            report["unwoven"].append({"script": script["path"], "line": line, "definition": dname, "why": "expression context"})
            continue
        args = call["args"]
        codec = gen.DEFS[dname]
        literal_vals = None
        if codec[0] == "record":
            fields = [f for f, _ in codec[1]]
            if len(args) != 1 or args[0]["type"] != "AstExprTable":
                report["unwoven"].append({"script": script["path"], "line": line, "definition": dname, "why": "argument not a table constructor"})
                continue
            items = args[0]["items"]
            keys = [it["key"]["value"] if it["kind"] == "record" and it["key"]["type"] == "AstExprConstantString" else None for it in items]
            if sorted(k for k in keys if k) != sorted(fields) or None in keys:
                report["unwoven"].append({"script": script["path"], "line": line, "definition": dname, "why": "keys differ from the record"})
                continue
            exprs = {it["key"]["value"]: it["value"] for it in items}
            consts = {f: e["value"] for f, e in exprs.items() if e["type"] in ("AstExprConstantString", "AstExprConstantNumber", "AstExprConstantBool")}
            if len(consts) == len(fields):
                literal_vals = consts
            order = [it["key"]["value"] for it in items]  # source evaluation order
        elif codec[0] == "union":
            report["unwoven"].append({"script": script["path"], "line": line, "definition": dname, "why": "union not in this prototype"})
            continue
        else:
            if len(args) != 1:
                report["unwoven"].append({"script": script["path"], "line": line, "definition": dname, "why": "argument count"})
                continue
            exprs, order = {"": args[0]}, [""]
        sites.append({"stmt": stmt, "def": dname, "exprs": exprs, "order": order, "literal": literal_vals, "line": line})
        accounted.add(id(idx))
    return (src, nodes, sites, accounted, bindings), sites

def emit_site(lines, site):
    """Replacement text for the call statement, with the same number of lines; each argument expression keeps
    its original text and starts on its original line; the encoder follows on the statement's last line."""
    l1, c1, l2, c2 = loc(site["stmt"]["location"])
    dname = site["def"]
    if site["literal"] is not None:
        gen.LITERAL_SITES[dname] = site["literal"]
        body = gen.woven_body(dname, literal=True)
        out, cur = "do", l1
    else:
        params = {p: f"__lync_a{i}" for i, p in enumerate(site["order"])}
        body = gen.woven_body(dname, params)
        out, cur = "do local " + ", ".join(params[p] for p in site["order"]) + " =", l1
        for i, p in enumerate(site["order"]):
            el1, ec1, el2, ec2 = loc(site["exprs"][p]["location"])
            while cur < el1:
                out += "\n"
                cur += 1
            out += (", " if i else " ") + text_span(lines, el1, ec1, el2, ec2)
            cur = el2
    while cur < l2:
        out += "\n"
        cur += 1
    # prefix runtime names so no user local can shadow them
    b = " ".join(body)
    b = re.sub(r"\b(begin|reserve|tail|fail|octa)\(", r"__lync_\1(", b)
    b = re.sub(r"\b(E_[A-Za-z0-9_]+)\b", r"__lync_\1", b)
    b = re.sub(r"\blocal b, p = ", "local __lync_b, __lync_p = ", b)
    b = re.sub(r"buffer\.writebits\(b, p ", "__lync_writebits(__lync_b, __lync_p ", b)
    b = re.sub(r"\bq(\d+)\b", r"__lync_q\1", b)
    return out + " " + b + " end", (l1, c1, l2, c2)

def splice(src, nodes, sites, bindings_locs):
    lines = src.split("\n")
    edits = []
    for s in sites:
        text, span = emit_site(lines, s)
        edits.append((span, text))
    # imports at the end of each binding statement, on its own last line (line count unchanged)
    imp = (" local __lync = Net.__lync local __lync_begin, __lync_reserve, __lync_tail, __lync_fail, __lync_octa = "
           "__lync.begin, __lync.reserve, __lync.tail, __lync.fail, __lync.octa local __lync_writebits = buffer.writebits")
    enums = sorted(gen.ENUMS)
    if enums:
        imp += " local " + ", ".join("__lync_" + e for e in enums) + " = " + ", ".join("__lync." + e for e in enums)
    for bl in bindings_locs:
        l1, c1, l2, c2 = loc(bl)
        edits.append(((l2, c2, l2, c2), imp))
    for (l1, c1, l2, c2), text in sorted(edits, key=lambda e: (e[0][0], e[0][1]), reverse=True):
        before = "\n".join(lines[:l1]) + ("\n" if l1 else "") + lines[l1][:c1]
        after = lines[l2][c2:] + ("\n" if l2 + 1 < len(lines) else "") + "\n".join(lines[l2 + 1:])
        src2 = before + text + after
        lines = src2.split("\n")
    return "\n".join(lines)

def main():
    scripts = json.load(open(IN))
    report = {"shard": SHARD, "unparsed": [], "escapes": [], "unwoven": [], "woven": [], "bindingStatements": {},
              "closed": [], "open": {}, "parseSeconds": 0.0, "totalSeconds": 0.0, "sourceBytes": 0}
    t0 = time.perf_counter()
    analysed = {}
    name_refs = {d: [] for d in gen.DEFS}
    for s in scripts:
        if s["path"] == SHARD:
            continue
        report["sourceBytes"] += len(s["source"])
        tp = time.perf_counter()
        res, sites = analyse(s, report)
        report["parseSeconds"] += time.perf_counter() - tp
        if res is None:
            continue
        analysed[s["path"]] = res
        src, nodes, sites, accounted, bindings = res
        for n, p, k in nodes:  # every occurrence of a definition name: anything.def or "def"
            nm = n.get("index") if n["type"] == "AstExprIndexName" else n.get("value") if n["type"] == "AstExprConstantString" else None
            if nm in name_refs and id(n) not in accounted:
                # an alias's own declaration (binding.def) counts as accounted when the alias is only used at sites
                name_refs[nm].append({"script": s["path"], "line": loc(n["location"])[0] + 1})
    # alias declarations: accounted only if every use of the alias was woven
    complete = not report["escapes"] and not report["unparsed"]
    unwoven_defs = {u["definition"] for u in report["unwoven"]}
    for d in gen.DEFS:
        refs = [r for r in name_refs[d] if not any(r["script"] == w["script"] for w in [])]
        stray = [r for r in refs if not alias_decl(analysed, r, d)]
        if complete and d not in unwoven_defs and not stray:
            report["closed"].append(d)
        else:
            why = "namespace incomplete" if not complete else "unwoven site" if d in unwoven_defs else f"name occurs outside a woven site: {stray[:3]}"
            report["open"][d] = why
    out = []
    for s in scripts:
        if s["path"] in analysed:
            src, nodes, sites, accounted, bindings = analysed[s["path"]]
            if sites:
                gen.ENUMS.clear()
                woven = splice(src, nodes, sites, report["bindingStatements"].get(s["path"], []))
                assert woven.count("\n") == src.count("\n"), "line count changed"
                report["woven"] += [{"script": s["path"], "line": x["line"], "definition": x["def"], "literal": x["literal"] is not None} for x in sites]
                s = dict(s, source=woven)
        out.append(s)
    report["totalSeconds"] = time.perf_counter() - t0
    json.dump(out, open(OUT, "w"), indent=1)
    json.dump(report, open(REPORT, "w"), indent=1)
    print(json.dumps({k: report[k] for k in ("closed", "open", "escapes", "unwoven")}, indent=1))

def alias_decl(analysed, ref, d):
    """True when the name occurrence is a definition alias declaration local x = binding.d (its uses are
    classified on their own)."""
    res = analysed.get(ref["script"])
    if not res:
        return False
    src, nodes, sites, accounted, bindings = res
    for n, p, k in nodes:
        if n["type"] == "AstStatLocal" and loc(n["location"])[0] + 1 == ref["line"]:
            for v in n["values"]:
                if v["type"] == "AstExprIndexName" and v["index"] == d and v["expr"]["type"] == "AstExprLocal" and local_id(v["expr"]["local"]) in bindings:
                    return True
    return False

main()
