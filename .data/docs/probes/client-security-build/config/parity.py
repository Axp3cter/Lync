"""Parse TOML files with three hosts and compare canonical JSON.
Usage: python3 -I parity.py <luau> <lute toml.luau> <node> <node_modules dir with smol-toml> <lune> <scratch dir> <file.toml>...
Hosts: Lute's batteries/toml.luau run by the plain luau CLI (the parser a Studio plugin would vendor),
smol-toml in Node (what a roblox-ts transformer would use), Lune 0.11.0 serde."""
import json, os, shutil, subprocess, sys

luau, toml_luau, node, node_modules, lune, scratch = sys.argv[1:7]
files = sys.argv[7:]
os.makedirs(scratch, exist_ok=True)
shutil.copy(toml_luau, os.path.join(scratch, "toml.luau"))
ENC = r'''
local function enc(v)
	local t = type(v)
	if t == "table" then
		if #v > 0 or next(v) == nil then
			local parts = {}
			for _, x in ipairs(v) do table.insert(parts, enc(x)) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local keys = {}
		for k in v do table.insert(keys, k) end
		table.sort(keys)
		local parts = {}
		for _, k in keys do table.insert(parts, string.format("%q", k) .. ":" .. enc(v[k])) end
		return "{" .. table.concat(parts, ",") .. "}"
	elseif t == "string" then
		return string.format("%q", v)
	elseif t == "number" then
		return if v == math.floor(v) and math.abs(v) < 2^63 then string.format("%d", v) else tostring(v)
	end
	return tostring(v)
end
'''
def canon(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), default=str)

for path in files:
    text = open(path).read()
    results = {}
    src = f'local toml = require("./toml")\n{ENC}\nprint(enc(toml.deserialize([==[{text}]==])))\n'
    lp = os.path.join(scratch, "parse.luau"); open(lp, "w").write(src)
    r = subprocess.run([luau, lp], capture_output=True, text=True, cwd=scratch)
    results["toml.luau (luau 0.740)"] = r.stdout.strip() or r.stderr.strip()
    js = ("const {parse}=require('smol-toml');const fs=require('fs');"
          "const o=parse(fs.readFileSync(process.argv[1],'utf8'));"
          "const c=v=>Array.isArray(v)?'['+v.map(c).join(',')+']':(v instanceof Date||(v&&v.constructor&&v.constructor.name.includes('Date')))?JSON.stringify(String(v)):(typeof v==='object'&&v)?'{'+Object.keys(v).sort().map(k=>JSON.stringify(k)+':'+c(v[k])).join(',')+'}':typeof v==='bigint'?v.toString():JSON.stringify(v);"
          "console.log(c(o))")
    r = subprocess.run([node, "-e", js, os.path.abspath(path)], capture_output=True, text=True, env={**os.environ, "NODE_PATH": node_modules})
    results["smol-toml (node)"] = r.stdout.strip() or next((l for l in r.stderr.splitlines() if l.startswith('Error')), r.stderr.strip())
    lsrc = f'local serde = require("@lune/serde")\n{ENC}\nprint(enc(serde.decode("toml", [==[{text}]==])))\n'
    lp2 = os.path.join(scratch, "parse_lune.luau"); open(lp2, "w").write(lsrc)
    r = subprocess.run([lune, "run", lp2], capture_output=True, text=True, cwd=scratch)
    results["lune serde"] = r.stdout.strip() or r.stderr.strip()
    print(f"== {os.path.basename(path)}")
    ref = None
    for host, out in results.items():
        same = "" if ref is None else ("  (same as first)" if out == ref else "  (DIFFERS)")
        ref = ref or out
        print(f"{host}:{same}\n  {out}")
