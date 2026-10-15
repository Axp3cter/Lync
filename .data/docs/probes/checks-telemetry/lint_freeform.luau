--!strict
-- Prototype of the U12 lint `freeFormField` (research/checks-telemetry.md, U12): walks the client-sent payloads
-- of a schema and names every free-form leaf with no `:input()` or `:claim()` on it or on an enclosing codec.
-- Codecs are stand-ins with v5.md §3.3's constructors and parameters; only what the rule reads is modelled.
-- Run: luau -O2 lint_freeform.luau
local MAX_CHOICES = 65536 -- the rule's threshold: a scalar with more than 2^16 encodable values is free-form

type Codec = { kind: string, role: string?, [string]: any }

local Codec = {}
Codec.__index = Codec
function Codec.input(self: Codec): Codec
	self.role = "input"
	return self
end
function Codec.claim(self: Codec): Codec
	self.role = "claim"
	return self
end
local function mk(kind: string, fields: { [string]: any }?): Codec
	local c: any = fields or {}
	c.kind = kind
	return setmetatable(c, Codec) :: any
end

local t = {
	bool = function() return mk("bool") end,
	int = function(min: number?, max: number?) return mk("int", { min = min, max = max }) end,
	number = function(min: number, max: number, step: number) return mk("number", { n = math.round((max - min) / step) }) end,
	f32 = function() return mk("f32") end,
	f64 = function() return mk("f64") end,
	angle = function(step: number) return mk("angle", { n = math.round(2 * math.pi / step) }) end,
	string = function(maxBytes: number) return mk("string", { maxBytes = maxBytes }) end,
	buffer = function(maxBytes: number) return mk("buffer", { maxBytes = maxBytes }) end,
	vector3 = function(min: number, max: number, step: number) return mk("vector3", { n = math.round((max - min) / step) }) end,
	vector3f32 = function() return mk("vector3f32") end,
	direction = function(bits: number) return mk("direction") end,
	rotation = function(bits: number) return mk("rotation") end,
	cframe = function(position: Codec, rotation: Codec) return mk("cframe", { position = position, rotation = rotation }) end,
	color3 = function() return mk("color3") end,
	enum = function(items: any) return mk("enum") end,
	instance = function(className: string?) return mk("instance") end,
	optional = function(c: Codec) return mk("optional", { inner = c }) end,
	array = function(c: Codec, maxCount: number) return mk("array", { inner = c }) end,
	map = function(k: Codec, v: Codec, maxCount: number) return mk("map", { key = k, value = v }) end,
	union = function(variants: { [string]: { [string]: Codec } }) return mk("union", { variants = variants }) end,
	custom = function(name: string) return mk("custom") end,
	convert = function(base: Codec) return mk("convert", { inner = base }) end,
}
local function record(fields: { [string]: Codec }): Codec
	return mk("record", { fields = fields })
end

-- Returns "free" with a reason, or nil when the leaf is input-shaped.
local function freeForm(c: Codec): string?
	local k = c.kind
	if k == "f32" or k == "f64" or k == "vector3f32" then
		return "unbounded float"
	elseif k == "int" then
		if c.min == nil then
			return "unbounded integer"
		end
		local n = c.max - c.min + 1
		return if n > MAX_CHOICES then string.format("integer with %.0f values", n) else nil
	elseif k == "number" or k == "vector3" then
		local n = c.n + 1
		return if n > MAX_CHOICES then string.format("quantized number with %.0f codes per component", n) else nil
	elseif k == "string" or k == "buffer" then
		return "free text or bytes"
	elseif k == "instance" then
		return "instance reference"
	elseif k == "custom" then
		return "custom codec"
	end
	return nil -- bool, enum, angle, direction, rotation, color3
end

local warnings = 0
local function walk(c: Codec, path: string, covered: boolean)
	covered = covered or c.role ~= nil
	local k = c.kind
	if k == "record" then
		local names = {}
		for name in c.fields do
			table.insert(names, name)
		end
		table.sort(names)
		for _, name in names do
			walk(c.fields[name], path .. "." .. name, covered)
		end
	elseif k == "optional" or k == "array" or k == "convert" then
		walk(c.inner, path, covered)
	elseif k == "map" then
		walk(c.key, path .. "[key]", covered)
		walk(c.value, path .. "[value]", covered)
	elseif k == "union" then
		local names = {}
		for name in c.variants do
			table.insert(names, name)
		end
		table.sort(names)
		for _, name in names do
			walk(record(c.variants[name]), path .. "." .. name, covered)
		end
	elseif k == "cframe" then
		walk(c.position, path .. "(position)", covered)
	else
		local why = freeForm(c)
		if why and not covered then
			warnings += 1
			print(string.format("warning[freeFormField]: %s is client-sent and free-form (%s); mark it :input() or :claim()", path, why))
		end
	end
end

-- Client-sent payloads: `data` of from = "client" events and requests, `reply` of from = "server" requests.
type Def = { from: string, data: Codec?, reply: Codec? }
local function lint(namespace: string, defs: { [string]: Def })
	local names = {}
	for name in defs do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		local d = defs[name]
		if d.from == "client" and d.data then
			walk(d.data, namespace .. "." .. name .. " data", false)
		elseif d.from == "server" and d.reply then
			walk(d.reply, namespace .. "." .. name .. " reply", false)
		end
	end
end

print("-- arena (v5.md §3.4), unannotated")
lint("arena", {
	chat = { from = "client", data = t.string(200) },
	strike = { from = "client", data = record({ target = t.int(1, 2 ^ 40), aim = t.direction(11) }) },
	announce = { from = "server", data = t.union({ round = { number = t.int(1, 99) } }) },
	buy = { from = "client", data = record({ item = t.enum({ "sword", "shield" }) }), reply = t.int(0, 100000) },
})

print("-- arena, annotated")
lint("arena", {
	chat = { from = "client", data = t.string(200):input() },
	strike = { from = "client", data = record({ target = t.int(1, 2 ^ 40):claim(), aim = t.direction(11) }) },
	buy = { from = "client", data = record({ item = t.enum({ "sword", "shield" }) }) },
})

print("-- outcome-shaped fields, and what the rule cannot see")
lint("demo", {
	collect = { from = "client", data = record({ coins = t.int(0, 1000000), coin = t.int(1, 500) }) },
	hit = { from = "client", data = record({ damage = t.f32(), part = t.instance("BasePart"), origin = t.vector3(-2048, 2048, 1 / 32) }) },
	finish = { from = "client", data = record({ won = t.bool(), place = t.int(1, 12), time = t.number(0, 600, 0.01) }) },
	move = { from = "client", data = record({ stick = t.vector3(-1, 1, 1 / 127), look = t.angle(2 * math.pi / 1024) }) },
	settings = { from = "client", data = record({ volume = t.number(0, 1, 1e-5), name = t.optional(t.string(20)) }) },
	confirm = { from = "server", reply = record({ accepted = t.bool(), note = t.string(50) }) },
})
print(string.format("%d warnings", warnings))
