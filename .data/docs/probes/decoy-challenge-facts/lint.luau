--!strict
-- Stand-in for the build check `decoyRef` (U11c): on stand-in codec descriptors and scanned server-script text,
-- report every client-sent leaf whose codec serialises like the key codec of a collection that has decoys, unless
-- `:refers(field, collection)` declares it. Codecs here are descriptors, not Lync's planner; the serialisation is a
-- stand-in for v5.md §4.7's canonical form (kind and parameters).
-- Run: luau lint.luau

type Codec = { kind: string, a: number?, b: number?, inner: Codec?, fields: { [string]: Codec }? }

local t = {}
function t.int(a: number, b: number): Codec return { kind = "int", a = a, b = b } end
function t.string(n: number): Codec return { kind = "string", a = n } end
function t.optional(c: Codec): Codec return { kind = "optional", inner = c } end
function t.array(c: Codec, n: number): Codec return { kind = "array", inner = c, a = n } end
function t.record(f: { [string]: Codec }): Codec return { kind = "record", fields = f } end
function t.direction(bits: number): Codec return { kind = "direction", a = bits } end

local function ser(c: Codec): string
	if c.kind == "int" then return `int({c.a},{c.b})` end
	if c.kind == "string" then return `string({c.a})` end
	if c.kind == "direction" then return `direction({c.a})` end
	return c.kind
end

type Def = { name: string, from: string, kind: string, data: Codec? }
type Coll = { name: string, key: Codec }

-- the arena schema of v5.md §3.4, plus a pickup collection and three client definitions that exercise the rule
local collections: { Coll } = {
	{ name = "fighters", key = t.int(1, 2 ^ 40) },
	{ name = "pickups", key = t.int(1, 4096) },
}
local defs: { Def } = {
	{ name = "chat", from = "client", kind = "event", data = t.string(200) },
	{ name = "strike", from = "client", kind = "event",
		data = t.record({ target = t.int(1, 2 ^ 40), aim = t.direction(11) }) },
	{ name = "collect", from = "client", kind = "event", data = t.record({ item = t.int(1, 4096) }) },
	{ name = "sweep", from = "client", kind = "event", data = t.record({ items = t.array(t.int(1, 4096), 16) }) },
	{ name = "tip", from = "client", kind = "event", data = t.record({ to = t.optional(t.int(1, 2 ^ 40)), amount = t.int(1, 100) }) },
	{ name = "trade", from = "client", kind = "event",
		data = t.record({ offers = t.array(t.record({ item = t.int(1, 4096), count = t.int(1, 99) }), 8) }) },
	{ name = "score", from = "client", kind = "event", data = t.record({ points = t.int(1, 2 ^ 40) }) },
}

-- scanned server-script text (the same pass as reachability, v5-integrity.md §3)
local serverText = [[
Net.fighters:decoys(fighterDecoys, { maxPerViewer = 1 })
Net.pickups:decoys(pickupDecoys, { maxPerViewer = 2 })
Net.strike:refers("target", "fighters")
Net.collect:refers("item", "pickups")
]]

local function hasDecoys(coll: string): boolean
	return string.find(serverText, `.{coll}:decoys(`, 1, true) ~= nil
end
local function hasRefers(def: string, field: string, coll: string): boolean
	return string.find(serverText, `.{def}:refers("{field}", "{coll}")`, 1, true) ~= nil
end

local function sortedKeys(m: { [string]: Codec }): { string }
	local ks = {}
	for k in m do table.insert(ks, k) end
	table.sort(ks)
	return ks
end

local reports = 0
local function walk(def: Def, c: Codec, path: string, top: string?, depth: number)
	if c.kind == "record" then
		local f = c.fields :: { [string]: Codec }
		for _, k in sortedKeys(f) do
			walk(def, f[k], if path == "" then k else `{path}.{k}`, if depth == 0 then k else top, depth + 1)
		end
		return
	end
	if c.kind == "optional" then walk(def, c.inner :: Codec, path, top, depth) return end
	if c.kind == "array" then walk(def, c.inner :: Codec, `{path}[]`, top, depth + 1) return end
	for _, coll in collections do
		if ser(c) == ser(coll.key) and hasDecoys(coll.name) then
			local declarable = top ~= nil and (path == top or path == `{top}[]`)
			if not (top ~= nil and hasRefers(def.name, top, coll.name)) then
				reports += 1
				print(string.format("warning[decoyRef]: arena.%s data.%s has the key codec of %s, which has decoys, and no :refers(\"%s\", \"%s\")%s",
					def.name, path, coll.name, top or path, coll.name,
					if declarable then "" else "; not declarable by :refers (not a top-level key, optional key or array of keys): report it with reportInteraction"))
			end
		end
	end
end

for _, def in defs do
	if def.from == "client" and def.data then
		walk(def, def.data :: Codec, "", nil, 0)
	end
end
print("reports", reports)
