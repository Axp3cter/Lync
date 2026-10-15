"""Fill template.luau for several seeds, compile each with luau-compile -O2, and compare instruction streams.
Usage: python3 -I compare.py <luau-compile> <luau> <outdir>
Prints, per function, instruction count and whether the opcode sequence matches seed 0, then a timing
comparison of the seed-0 shard against runtime.luau."""
import re, subprocess, sys, os, random

compile_bin, luau_bin, out = sys.argv[1], sys.argv[2], sys.argv[3]
here = os.path.dirname(os.path.abspath(__file__))
template = open(os.path.join(here, "template.luau")).read()
FIELDS = {
    "target": "\tbuffer.writeu16(b, o, v.target); o += 2",
    "damage": "\tbuffer.writeu16(b, o, v.damage); o += 2",
    "crit": "\tbuffer.writeu8(b, o, if v.crit then 1 else 0); o += 1",
}

def variant(seed):
    rng = random.Random(seed)  # the probe's own seeding; the real generator uses its xorshift32
    consts = [0x736F6D65, 0x646F7261, 0x6C796765, 0x74656462] if seed == 0 else [rng.getrandbits(32) for _ in range(4)]
    order = ["target", "damage", "crit"]
    ids = [1, 2, 3]
    if seed:
        rng.shuffle(order); rng.shuffle(ids)
    s = template
    for i, c in enumerate(consts):
        s = s.replace(f"@C{i}", hex(c))
    s = s.replace("@ID_HIT", str(ids[0])).replace("@ID_SHOOT", str(ids[1])).replace("@ID_RELOAD", str(ids[2]))
    s = s.replace("@FIELDS", "\n".join(FIELDS[f] for f in order))
    path = os.path.join(out, f"seed{seed}.luau")
    open(path, "w").write(s)
    return path

def functions(path):
    text = subprocess.run([compile_bin, "--text", "-O2", path], capture_output=True, text=True, check=True).stdout
    funcs, cur = {}, None
    for line in text.splitlines():
        m = re.match(r"Function \d+ \((\w+)\)", line)
        if m:
            cur = m.group(1); funcs[cur] = []
        elif cur:
            tokens = [t for t in line.split() if re.fullmatch(r"[A-Z][A-Z0-9_]+", t) and t != "REMARK"]
            if tokens:
                funcs[cur].append(tokens[0])
    return funcs

os.makedirs(out, exist_ok=True)
paths = {seed: variant(seed) for seed in (0, 7, 8, 12345)}
paths["runtime"] = os.path.join(here, "runtime.luau")
streams = {k: functions(p) for k, p in paths.items()}
base = streams[0]
for name in ("tagWord", "writeHit", "dispatch"):
    row = [f"{name}: seed0 {len(base[name])} instr"]
    for k in (7, 8, 12345, "runtime"):
        s = streams[k].get(name, [])
        verdict = "same sequence" if s == base[name] else ("same multiset, reordered" if sorted(s) == sorted(base[name]) else "different")
        row.append(f"{k}: {len(s)} {verdict}")
    print("; ".join(row))
print("tagWord opcodes seed0:", " ".join(base["tagWord"]))
print("tagWord opcodes runtime:", " ".join(streams["runtime"]["tagWord"]))

bench = r'''
local M = require("./%s")
local b = buffer.create(64)
local N = 2000000
local function best(f)
	local m = math.huge
	for _ = 1, 7 do
		local t = os.clock(); f(); m = math.min(m, os.clock() - t)
	end
	return m / N * 1e9
end
local v = { target = 7, damage = 30, crit = true }
local tw, wh, dp = M.tagWord, M.writeHit, M.dispatch
print(string.format("%%s tagWord %%.1f ns, writeHit %%.1f ns, dispatch %%.1f ns", "%s",
	best(function() local x = 0 for i = 1, N do x = tw(i, x, i) end end),
	best(function() for _ = 1, N do wh(b, 0, v) end end),
	best(function() for i = 1, N do dp(1 + i %% 3, b, 0) end end)))
'''
import shutil
for name, path in (("seed0", paths[0]), ("seed7", paths[7]), ("runtime", paths["runtime"])):
    shutil.copy(path, os.path.join(out, f"m_{name}.luau"))
    bp = os.path.join(out, f"bench_{name}.luau")
    open(bp, "w").write(bench % (f"m_{name}", name))
    for _ in range(3):
        print(subprocess.run([luau_bin, "-O2", bp], capture_output=True, text=True, cwd=out).stdout.strip())
