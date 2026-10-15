--!nocheck
-- Seeded decode fuzzer. For random codecs (test/support/gen.luau), decodes random bytes and bit-flipped
-- valid payloads, in single rows and column blocks. Records (a) any raise, (b) any accepted
-- single-row payload whose decoded value re-encodes to different bytes (a second encoding of one
-- value, v5.md §4.8), skipping column blocks, whose mode and k are free choices.
-- Run: lune run p5_fuzz.luau [seed] [cases]
local process = require("@lune/process")
local P = require("./prelude")
local Gen = require("../../../../test/support/gen")
local Bits, Run, Column = P.Bits, P.Run, P.Column

local seed = tonumber(process.args[1]) or 1
local cases = tonumber(process.args[2]) or 20000
math.randomseed(seed)

local pool = { Instance.new("Part"), Instance.new("Model"), Instance.new("Part") }

local function kindsOf(codec, into)
	into[codec.kind] = true
	if codec.kind == "record" then
		for _, f in codec.fields do kindsOf(f.codec, into) end
	elseif codec.kind == "union" then
		for _, v in codec.variants do kindsOf(v.record, into) end
	elseif codec.kind == "optional" or codec.kind == "array" then
		kindsOf(codec.inner, into)
	elseif codec.kind == "map" then
		kindsOf(codec.key, into); kindsOf(codec.value, into)
	elseif codec.kind == "cframe" then
		kindsOf(codec.position, into); kindsOf(codec.rotation, into)
	elseif codec.kind == "convert" then
		kindsOf(codec.base, into)
	end
	return into
end

local function hasBlock(value)
	if typeof(value) ~= "table" then return false end
	local n = 0
	for _, v in value do
		n += 1
		if hasBlock(v) then return true end
	end
	return n >= Column.MIN_ROWS and value.kind == nil and #value == n or (n >= Column.MIN_ROWS and value.kind == nil and #value == 0)
end

local function encode(codec, values, count)
	local instances = { list = {}, index = {} }
	Run.collect(codec, values, count, instances)
	local w = Bits.writer()
	Run.encode(w, codec, values, count, instances, "p.e:fire")
	return Bits.finish(w), instances.list
end

local function randomBytes(n)
	local b = buffer.create(n)
	for i = 0, n - 1 do buffer.writeu8(b, i, math.random(0, 255)) end
	return b
end

local raised, accepted, nonCanonical, checked = 0, 0, 0, 0
local examples = {}
for case = 1, cases do
	local planned
	while planned == nil do
		local ok, c = pcall(Gen.plan, Gen.codec(3, math.random(1, 40)))
		planned = if ok then c else nil
	end
	local count = math.random(1, 2 * Column.MIN_ROWS + 1)
	local bytes, list
	if math.random() < 0.5 then
		bytes = randomBytes(math.random(0, 24))
		list = { pool[1], pool[2] }
	else
		local values = {}
		local style = Gen.style(pool)
		for i = 1, count do values[i] = Gen.value(planned, 6, style) end
		bytes, list = encode(planned, values, count)
		for _ = 1, math.random(1, 3) do
			if buffer.len(bytes) > 0 then
				local bit = math.random(0, buffer.len(bytes) * 8 - 1)
				buffer.writeu8(bytes, bit // 8, bit32.bxor(buffer.readu8(bytes, bit // 8), bit32.lshift(1, bit % 8)))
			end
		end
	end

	local out = {}
	local r = Bits.reader(bytes)
	local ok, rule = pcall(Run.decode, r, planned, count, list, out)
	if not ok then
		raised += 1
		if #examples < 5 then table.insert(examples, `case {case}: raised {rule} (codec {planned.kind})`) end
		continue
	end
	if rule ~= 0 or not Bits.meets(r) then continue end
	accepted += 1

	local kinds = kindsOf(planned, {})
	if count >= Column.MIN_ROWS or kinds.robloxEnum or kinds.instance or hasBlock(out) then continue end
	checked += 1
	local okEncode, again = pcall(encode, planned, out, count)
	if not okEncode or buffer.tostring(again) ~= buffer.tostring(bytes) then
		nonCanonical += 1
		if process.args[3] == "dump" then
			local function dump(v, depth)
				depth = depth or 0
				if typeof(v) == "table" then
					local parts = {}
					for k, x in v do table.insert(parts, tostring(k) .. "=" .. dump(x, depth + 1)) end
					return "{" .. table.concat(parts, ", ") .. "}"
				end
				return tostring(v)
			end
			local function codecText(c)
				if c.kind == "record" then
					local parts = {}
					for _, f in c.fields do table.insert(parts, f.name .. "=" .. codecText(f.codec)) end
					return "{" .. table.concat(parts, ", ") .. "}"
				elseif c.kind == "optional" then return "optional(" .. codecText(c.inner) .. ")"
				elseif c.kind == "array" then return "array(" .. codecText(c.inner) .. ", " .. c.max .. ")"
				elseif c.kind == "map" then return "map(" .. codecText(c.key) .. ", " .. codecText(c.value) .. ", " .. c.max .. ")"
				elseif c.kind == "union" then
					local parts = {}
					for _, v in c.variants do table.insert(parts, v.name .. "=" .. codecText(v.record)) end
					return "union{" .. table.concat(parts, ", ") .. "}"
				end
				return c.kind
			end
			print(`case {case}: codec {codecText(planned)}, count {count}, decoded {dump(out)}`)
			print("  sent    " .. buffer.tostring(bytes):gsub(".", function(c) return string.format("%02x ", string.byte(c)) end))
			if okEncode then print("  re-enc  " .. buffer.tostring(again):gsub(".", function(c) return string.format("%02x ", string.byte(c)) end)) end
		end
		local whatKinds = {}
		for k in kinds do table.insert(whatKinds, k) end
		table.sort(whatKinds)
		if #examples < 12 then
			table.insert(examples, `case {case}: accepted payload re-encodes differently ({if okEncode then "different bytes" else "encode raised: " .. tostring(again)}); kinds {table.concat(whatKinds, ",")}`)
		end
	end
end

print(string.format("seed %d, %d cases: %d raised, %d accepted, %d single-row acceptances checked, %d non-canonical", seed, cases, raised, accepted, checked, nonCanonical))
for _, e in examples do print("  " .. e) end
