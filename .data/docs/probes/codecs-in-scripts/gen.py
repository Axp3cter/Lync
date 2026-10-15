"""Generates the codecs-in-scripts probe sources: a runtime model, a client shard, and game scripts in
unwoven and woven forms, for timing (bench) and bytecode size (size). Encoders follow v5.md single-row
encoding (fields in order, LSB-first bits through buffer.writebits, strings in a tail) with check-then-write.

Usage: python3 -I gen.py OUTDIR
"""
import math, os, sys


def bits_for(n):  # u(ceil(log2 n)) for n codes
    return 0 if n <= 1 else math.ceil(math.log2(n))

# Codec specs. Leaves: ("int", min, max) ("bool",) ("number", min, max, step) ("enum", [items])
# ("direction", bits) ("string", maxBytes). Records: ("record", [(name, codec)]) in wire order.
# Unions: ("union", [(name, record)]).
DEFS = {
    "strike": ("record", [("target", ("int", 1, 2 ** 40)), ("aim", ("direction", 11))]),
    "move6": ("record", [("a", ("int", 0, 1000)), ("b", ("int", 0, 1000)), ("c", ("bool",)),
                         ("d", ("number", 0, 1, 1 / 1024)), ("e", ("enum", ["x", "y", "z"])), ("f", ("int", 0, 255))]),
    "chat": ("string", 200),
    "buy": ("record", [("item", ("enum", ["shield", "sword"]))]),
    "announce": ("union", [("round", ("record", [("number", ("int", 1, 99))])),
                           ("winner", ("record", [("team", ("enum", ["blue", "red"]))]))]),
}
IDS = {name: i for i, name in enumerate(sorted(DEFS))}
ID_BITS = bits_for(len(DEFS))

def leaf_width(c):
    k = c[0]
    if k == "int": return bits_for(c[2] - c[1] + 1)
    if k == "bool": return 1
    if k == "number": return bits_for(round((c[2] - c[1]) / c[3]) + 1)
    if k == "enum": return bits_for(len(c[1]))
    if k == "direction": return 2 * c[1]
    if k == "string": return bits_for(c[1] + 1)
    raise ValueError(k)

class Emit:
    """Emits check-then-write code for one value. `acc` maps a leaf path to a Luau expression or a
    Python constant (Const) known at build time."""
    def __init__(self, path_prefix):
        self.checks, self.pre, self.writes, self.width, self.n = [], [], [], 0, 0
        self.prefix = path_prefix
        self.const_bits = []  # (offset, width, value) for build-time constants

    def tmp(self):
        self.n += 1
        return f"q{self.n}"

    def leaf(self, c, x, path):
        k, w, off = c[0], leaf_width(c), self.width
        fail = f'fail("valueRefused", "{self.prefix}{path}", {x if not isinstance(x, Const) else "nil"})'
        if isinstance(x, Const):
            v = x.v
            code = {"int": lambda: v - c[1], "bool": lambda: 1 if v else 0,
                    "enum": lambda: c[1].index(v)}[k]()
            assert 0 <= code < 2 ** max(w, 1)
            self.const_bits.append((off, w, code))
        elif k == "int":
            self.checks.append(f"if type({x}) ~= \"number\" or {x} ~= {x} // 1 or {x} < {c[1]} or {x} > {c[2]} then {fail} end")
            self.write(off, w, f"{x} - {c[1]}")
        elif k == "bool":
            self.checks.append(f"if type({x}) ~= \"boolean\" then {fail} end")
            self.write(off, w, f"if {x} then 1 else 0")
        elif k == "number":
            n = round((c[2] - c[1]) / c[3])
            self.checks.append(f"if type({x}) ~= \"number\" or not ({x} >= {c[1]} and {x} <= {c[2]}) then {fail} end")
            q = self.tmp()
            self.pre.append(f"local {q} = math.min(math.floor(({x} - {c[1]}) / {c[3]!r} + 0.5), {n})")
            self.write(off, w, q)
        elif k == "enum":
            q = self.tmp()
            ENUMS[enum_name(c[1])] = c[1]
            self.checks.append(f"local {q} = {enum_name(c[1])}[{x}] if {q} == nil then {fail} end")
            self.write(off, w, q)
        elif k == "direction":
            qx, qy = self.tmp(), self.tmp()
            self.checks.append(f"if type({x}) ~= \"vector\" then {fail} end")
            self.pre.append(f"local {qx}, {qy} = octa({x}, {c[1]})")
            self.write(off, c[1], qx)
            self.write(off + c[1], c[1], qy)
        elif k == "string":
            self.checks.append(f"if type({x}) ~= \"string\" or #{x} > {c[1]} then {fail} end")
            self.write(off, w, f"#{x}")
            self.pre.append(f"tail({x})")
        self.width += w

    def write(self, off, w, expr):
        if w > 32:
            self.writes.append(f"buffer.writebits(b, p + {off}, 32, ({expr}) % 4294967296)")
            self.writes.append(f"buffer.writebits(b, p + {off + 32}, {w - 32}, ({expr}) // 4294967296)")
        elif w > 0:
            self.writes.append(f"buffer.writebits(b, p + {off}, {w}, {expr})")

    def flush_consts(self):
        # pack constant fields into 32-bit words
        words = {}
        for off, w, v in self.const_bits:
            for i in range(w):
                bit = (v >> i) & 1
                pos = off + i
                words.setdefault(pos // 32, 0)
                words[pos // 32] |= bit << (pos % 32)
        for wi, val in sorted(words.items()):
            lo = wi * 32
            hi = min(self.width, lo + 32)
            self.writes.append(f"buffer.writebits(b, p + {lo}, {hi - lo}, {val})")

ENUMS = {}
def enum_name(items):
    return "E_" + "_".join(items)

def enum_decls():
    return [f"local {n} = {{ " + ", ".join(f'["{x}"] = {i}' for i, x in enumerate(items)) + " }" for n, items in sorted(ENUMS.items())]

class Const:
    def __init__(self, v): self.v = v

def body(name, codec, acc, def_id, id_bits, indent="\t"):
    """acc: function(path) -> Luau expression or Const. Returns a list of statements."""
    lines = []
    def emit_record(rec, e, base):
        for fname, fc in rec[1]:
            e.leaf(fc, acc(base + fname), base + fname)
    def finish(e):
        e.flush_consts()
        out = list(e.checks) + [f"begin({def_id}, {id_bits})"] + list(e.pre)
        if e.width > 0:
            out.append(f"local b, p = reserve({e.width})")
            out += e.writes
        return out
    if codec[0] == "record":
        e = Emit(f"{name} data.")
        emit_record(codec, e, "")
        lines += finish(e)
    elif codec[0] == "union":
        kind = acc("kind")
        vbits = bits_for(len(codec[1]))
        if isinstance(kind, Const):
            idx = [n for n, _ in codec[1]].index(kind.v)
            vname, rec = codec[1][idx]
            e = Emit(f"{name} data.")
            e.const_bits.append((0, vbits, idx)); e.width = vbits
            emit_record(rec, e, "")
            lines += finish(e)
        else:
            first = True
            for idx, (vname, rec) in enumerate(codec[1]):
                e = Emit(f"{name} data.")
                e.write(0, vbits, str(idx)); e.width = vbits
                emit_record(rec, e, "")
                kw = "if" if first else "elseif"
                first = False
                lines.append(f"{kw} {kind} == \"{vname}\" then")
                lines += ["\t" + s for s in finish(e)]
            lines.append(f"else fail(\"valueRefused\", \"{name} data.kind\", {kind}) end")
    else:
        e = Emit(f"{name} data")
        e.leaf(codec, acc(""), "")
        lines += finish(e)
    return [indent + s for s in lines]

def leaf_paths(codec, variant=None):
    if codec[0] == "record":
        return [f for f, _ in codec[1]]
    if codec[0] == "union":
        rec = dict(codec[1])[variant]
        return [f for f, _ in rec[1]]
    return [""]

RT_IMPORTS = "local begin, reserve, tail, fail, octa = RT.begin, RT.reserve, RT.tail, RT.fail, RT.octa"

def shard():
    s = ["--!optimize 2", "-- client shard model: per-definition encoders taking the payload table",
         RT_IMPORTS, "local mark, rollback = RT.mark, RT.rollback", "local Net = {}", "local Internal = {}"]
    for name, codec in sorted(DEFS.items()):
        s.append(f"local function enc_{name}(v)")
        if codec[0] == "record":
            s += [f"\tlocal f_{p} = v.{p}" for p in leaf_paths(codec)]
            acc = lambda p: f"f_{p}"
        elif codec[0] == "union":
            s.append("\tlocal f_kind = v.kind")
            acc = lambda p: "f_kind" if p == "kind" else f"v.{p}"
        else:
            acc = lambda p: "v"
        s += body(name, codec, acc, IDS[name], ID_BITS)
        s.append("end")
        # S0: the spec's public entry with rollback pcall; S1: check-then-write, no pcall
        s.append(f"Net.{name} = {{ fire = function(self, v) local m = mark() local ok, err = pcall(enc_{name}, v) if not ok then rollback(m) error(err, 0) end end,")
        s.append(f"\tfireDirect = function(self, v) enc_{name}(v) end }}")
        # scalar entry used by the "direct call" woven form
        if codec[0] != "union":
            params = [f"a{i}" for i, _ in enumerate(leaf_paths(codec))]
            mp = dict(zip(leaf_paths(codec), params))
            s.append(f"function Internal.{name}({', '.join(params)})")
            s += body(name, codec, lambda p: mp[p], IDS[name], ID_BITS)
            s.append("end")
    s[3:3] = enum_decls()
    s.append("Net.__internal = Internal")
    s.append("return Net")
    return "\n".join(s) + "\n"

RT = r"""--!optimize 2
-- runtime model: one upstream writer, runs of one id, a string tail, octahedral quantizer with the canonical check
local buf = buffer.create(1048576)
local pos, lastId, count, tailN = 0, -1, 0, 0
local tailList = table.create(1024)
local RT = {}
function RT.reset() pos = 0 lastId = -1 tailN = 0 end
function RT.begin(id: number, idBits: number)
	if id == lastId then count += 1 return end
	lastId = id count = 1
	buffer.writebits(buf, pos, idBits, id) pos += idBits
end
function RT.reserve(n: number): (buffer, number)
	local p = pos pos = p + n return buf, p
end
function RT.tail(s: string) tailN += 1 tailList[tailN] = s end
function RT.mark() return pos * 65536 + tailN end
function RT.rollback(m: number) pos = m // 65536 tailN = m % 65536 end
function RT.fail(code: string, path: string, got: any): never
	error(string.format("[Lync] %s: %s must be in range, got %s", code, path, tostring(got)), 0)
end
local function octaEncode(x: number, y: number, z: number, bits: number): (number, number)
	local s = math.abs(x) + math.abs(y) + math.abs(z)
	local px, py = x / s, y / s
	if z < 0 then
		local ox, oy = px, py
		px = (1 - math.abs(oy)) * (if ox >= 0 then 1 else -1)
		py = (1 - math.abs(ox)) * (if oy >= 0 then 1 else -1)
	end
	local m = 2 ^ bits - 1
	return math.floor((px + 1) / 2 * m + 0.5), math.floor((py + 1) / 2 * m + 0.5)
end
local function octaDecode(qx: number, qy: number, bits: number): vector
	local m = 2 ^ bits - 1
	local cx, cy = 2 * qx / m - 1, 2 * qy / m - 1
	local z = 1 - math.abs(cx) - math.abs(cy)
	if z < 0 then
		local ox, oy = cx, cy
		cx = (1 - math.abs(oy)) * (if ox >= 0 then 1 else -1)
		cy = (1 - math.abs(ox)) * (if oy >= 0 then 1 else -1)
	end
	return vector.normalize(vector.create(cx, cy, z))
end
function RT.octa(v: vector, bits: number): (number, number)
	if v.x == 0 and v.y == 0 and v.z == 0 then RT.fail("valueRefused", "direction", v) end
	local qx, qy = octaEncode(v.x, v.y, v.z, bits)
	for _ = 1, 4 do -- canonical: iterate E(q) = encode(decode(q)) to a fixed point (v5.md §3.3)
		local d = octaDecode(qx, qy, bits)
		local ex, ey = octaEncode(d.x, d.y, d.z, bits)
		if ex == qx and ey == qy then return qx, qy end
		qx, qy = ex, ey
	end
	error("internal", 0)
end
return RT
"""

# call-site argument expressions used by the bench loops (vary per iteration)
SITE_ARGS = {
    "strike": {"target": "i", "aim": "dirs[i % 64 + 1]"},
    "move6": {"a": "i % 1000", "b": "(i * 7) % 1000", "c": "i % 2 == 0", "d": "(i % 1024) / 1024", "e": "abc[i % 3 + 1]", "f": "i % 256"},
    "chat": {"": "words[i % 16 + 1]"},
}
LITERAL_SITES = {  # sites whose payload is a literal (constant folding applies)
    "buy": {"item": "sword"},
    "announce": {"kind": "round", "number": 3},
}

def table_expr(name):
    codec = DEFS[name]
    if name in LITERAL_SITES:
        return "{ " + ", ".join(f'{k} = {lua_lit(v)}' for k, v in LITERAL_SITES[name].items()) + " }"
    args = SITE_ARGS[name]
    if codec[0] == "record":
        return "{ " + ", ".join(f"{k} = {v}" for k, v in args.items()) + " }"
    return args[""]

def lua_lit(v):
    return f'"{v}"' if isinstance(v, str) else repr(v)

def woven_body(name, scalar_names=None, literal=False):
    codec = DEFS[name]
    if literal:
        lit = LITERAL_SITES[name]
        return body(name, codec, lambda p: Const(lit[p]), IDS[name], ID_BITS, indent="")
    return body(name, codec, lambda p: scalar_names[p], IDS[name], ID_BITS, indent="")

def bench_script(name, form):
    """Returns a game-script model with a timed loop around one call site in the given form."""
    codec = DEFS[name]
    head = ["--!optimize 2", "local Net, RT = Net, RT", RT_IMPORTS,
            "local dirs = {} for k = 1, 64 do dirs[k] = vector.normalize(vector.create(math.sin(k), math.cos(k * 3), math.sin(k * 7))) end",
            'local abc = { "x", "y", "z" }',
            'local words = {} for k = 1, 16 do words[k] = string.rep("w", k * 3) end']
    literal = name in LITERAL_SITES
    paths = leaf_paths(codec, LITERAL_SITES.get(name, {}).get("kind")) if not literal else []
    if form == "S0":
        site = f"Net.{name}:fire({table_expr(name)})"
    elif form == "S1":
        site = f"Net.{name}:fireDirect({table_expr(name)})"
    elif form in ("W1", "W1n", "W1t", "W2", "W3"):
        if literal:
            fn = woven_body(name, literal=True)
            params, args = [], []
        else:
            params = [f"a{i}" for i in range(len(paths))]
            args = [SITE_ARGS[name][p] for p in paths]
            fn = woven_body(name, dict(zip(paths, params)))
        if form == "W1":
            head.append(f"local function __lync_{name}({', '.join(params)}) " + " ".join(fn) + " end")
            site = f"__lync_{name}({', '.join(args)})"
        elif form == "W1n":
            head.append(f"@native local function __lync_{name}({', '.join(params)}) " + " ".join(fn) + " end")
            site = f"__lync_{name}({', '.join(args)})"
        elif form == "W1t":
            head.append(f"local __lync = {{}} function __lync.{name}({', '.join(params)}) " + " ".join(fn) + " end")
            site = f"__lync.{name}({', '.join(args)})"
        elif form == "W2":
            pre = f"local {', '.join(params)} = {', '.join(args)} " if params else ""
            site = "do " + pre + " ".join(fn) + " end"
        else:
            if literal:
                return None
            head.append("local Internal = Net.__internal")
            site = f"Internal.{name}({', '.join(args)})"
    head[3:3] = enum_decls()
    loop = f"""
local N = 200000
local samples = {{}}
for rep = 1, 11 do
	local t0 = os.clock()
	for i = 1, N do
		{site}
		if i % 256 == 0 then RT.reset() end
	end
	samples[rep] = (os.clock() - t0) / N * 1e9
end
table.sort(samples)
print(string.format('{{"def":"%s","form":"%s","ns":%.1f,"min":%.1f,"max":%.1f}}', "{name}", "{form}", samples[6], samples[1], samples[11]))
return nil
"""
    return "\n".join(head) + "\n" + loop

def main_bench(OUT):
  os.makedirs(OUT, exist_ok=True)
  with open(os.path.join(OUT, "rt.luau"), "w") as f: f.write(RT)
  with open(os.path.join(OUT, "shard.luau"), "w") as f: f.write(shard())
  for name in DEFS:
    for form in ("S0", "S1", "W1", "W1n", "W1t", "W2", "W3"):
        src = bench_script(name, form)
        if src:
            with open(os.path.join(OUT, f"bench_{name}_{form}.luau"), "w") as f: f.write(src)
  print("ok", OUT)

# --- server-side decode: payload table to the handler (D0) against fields as arguments (D1) ---
DEC_SHARD = r"""--!optimize 2
-- server shard model: move6 decode with v5's range checks (rule 3), then delivery to each connected handler
local E_x_y_z = { "x", "y", "z" }
local Dec = {}
local function read(b: buffer, p: number)
	local a = buffer.readbits(b, p, 10) local bb = buffer.readbits(b, p + 10, 10)
	local c = buffer.readbits(b, p + 20, 1) local q = buffer.readbits(b, p + 21, 11)
	local e = buffer.readbits(b, p + 32, 2) local f = buffer.readbits(b, p + 34, 8)
	if a > 1000 or bb > 1000 or q > 1024 or e > 2 then return nil end
	return a, bb, c == 1, math.min(q * (1 / 1024), 1), E_x_y_z[e + 1], f
end
-- D0: one table per message, handlers receive (player, value)
function Dec.deliverTable(b: buffer, p: number, player: any, handlers: { any })
	local a, bb, c, d, e, f = read(b, p)
	if a == nil then return 3 end
	local v = { a = a, b = bb, c = c, d = d, e = e, f = f }
	for i = 1, #handlers do handlers[i](player, v) end
	return 0
end
-- D1: woven handler, fields as arguments, no table
function Dec.deliverFields(b: buffer, p: number, player: any, handlers: { any })
	local a, bb, c, d, e, f = read(b, p)
	if a == nil then return 3 end
	for i = 1, #handlers do handlers[i](player, a, bb, c, d, e, f) end
	return 0
end
return Dec
"""

def dec_bench(form):
    if form == "D0":
        handler = "function(player, v) sink += v.a + v.b + (if v.c then 1 else 0) + v.d + #v.e + v.f end"
        call = "Dec.deliverTable(b, (i % 64) * 42, player, handlers)"
    else:
        handler = "function(player, a, b, c, d, e, f) sink += a + b + (if c then 1 else 0) + d + #e + f end"
        call = "Dec.deliverFields(b, (i % 64) * 42, player, handlers)"
    return f"""--!optimize 2
local Dec = Dec
local sink = 0
local handlers = {{ {handler} }}
local player = {{}}
local b = buffer.create(4096)
for k = 0, 63 do
	local p = k * 42
	buffer.writebits(b, p, 10, (k * 13) % 1001) buffer.writebits(b, p + 10, 10, (k * 7) % 1001)
	buffer.writebits(b, p + 20, 1, k % 2) buffer.writebits(b, p + 21, 11, (k * 16) % 1025)
	buffer.writebits(b, p + 32, 2, k % 3) buffer.writebits(b, p + 34, 8, k)
end
local N = 400000
local samples = {{}}
for rep = 1, 11 do
	local t0 = os.clock()
	for i = 1, N do
		{call}
	end
	samples[rep] = (os.clock() - t0) / N * 1e9
end
table.sort(samples)
print(string.format('{{"def":"move6","form":"{form}","ns":%.1f,"min":%.1f,"max":%.1f}}', samples[6], samples[1], samples[11]))
return nil
"""

def main_dec(OUT):
    with open(os.path.join(OUT, "dec_shard.luau"), "w") as f: f.write(DEC_SHARD)
    for form in ("D0", "D1"):
        with open(os.path.join(OUT, f"dec_move6_{form}.luau"), "w") as f: f.write(dec_bench(form))

if __name__ == "__main__":
    main_bench(sys.argv[1])
    main_dec(sys.argv[1])
