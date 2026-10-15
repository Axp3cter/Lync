--!nocheck
-- The shape set: every codec kind a client can send on the CLI host, each as a record of n fields of that kind
-- (n = 1 and 16), in four forms, plus the composite, nested, long-string and busy shapes. Shared by the frame
-- builder (build_frames.luau, which fills values) and the timing probes (which only need the schema and the case
-- list). Not covered here: t.custom and t.convert (their decode is game code, outside the bound like validators).
--
-- Forms (v5.md §4.3, §4.8):
--   row1  one message alone in a frame (row form)
--   runs  one-message runs alternating between two definitions of the same codec (row form, a run header each)
--   colC  one run of many messages, every value the same (column form, mode 0 columns)
--   colR  one run of many messages, random values (column form, modes 1-3)
-- Each frame holds as many messages as fit in 16,380 B (16,384 less the milestone's 2-byte tag), at most CAP.

return function(Lync, R)
	local t = Lync.types
	local CAP = 512

	local LETTERS = "abcdefghijklmnopqrstuvwxyz"
	local function word(n)
		local s = table.create(n)
		for i = 1, n do
			local k = math.random(1, 26)
			s[i] = string.sub(LETTERS, k, k)
		end
		return table.concat(s)
	end
	local function unit()
		while true do
			local x, y, z = math.random() * 2 - 1, math.random() * 2 - 1, math.random() * 2 - 1
			local m = math.sqrt(x * x + y * y + z * z)
			if m > 0.1 and m <= 1 then
				return x / m, y / m, z / m
			end
		end
	end
	local function randomRotation()
		local a, b, c = unit()
		local w = math.random() * 2 - 1
		return R.CFrame.new(0, 0, 0, a, b, c, w)
	end
	local INSTANCES = {}
	for i = 1, 8 do
		INSTANCES[i] = R.newInstance()
	end
	local ANGLE_STEP = 2 * math.pi / 4096

	-- kind name -> { codec constructor, random value, constant value }
	local KINDS = {
		{ "bool", function() return t.bool() end, function() return math.random() < 0.5 end, function() return false end },
		{ "int8", function() return t.int(0, 255) end, function() return math.random(0, 255) end, function() return 7 end },
		{ "int32", function() return t.int(0, 4294967295) end, function() return math.floor(math.random() * 4294967296) end, function() return 7 end },
		{ "varint", function() return t.int() end, function()
			return (if math.random() < 0.5 then -1 else 1) * math.floor(2 ^ (math.random() * 20))
		end, function() return 0 end },
		{ "number", function() return t.number(0, 1, 1 / 1024) end, function() return math.random(0, 1024) / 1024 end, function() return 0 end },
		{ "f32", function() return t.f32() end, function() return math.random(-1000000, 1000000) / 1024 end, function() return 0 end },
		{ "f64", function() return t.f64() end, function() return math.random() * 1e6 end, function() return 0 end },
		{ "angle", function() return t.angle(ANGLE_STEP) end, function() return math.random(0, 4095) * ANGLE_STEP end, function() return 0 end },
		{ "enum3", function() return t.enum({ "a", "b", "c" }) end, function() return ({ "a", "b", "c" })[math.random(1, 3)] end, function() return "a" end },
		{ "str8", function() return t.string(16) end, function() return word(8) end, function() return "aaaaaaaa" end },
		{ "buf8", function() return t.buffer(16) end, function() return buffer.fromstring(word(8)) end, function() return buffer.fromstring("aaaaaaaa") end },
		{ "vector3", function() return t.vector3(-1024, 1024, 1 / 64) end, function()
			return vector.create(math.random(-65536, 65536) / 64, math.random(-65536, 65536) / 64, math.random(-65536, 65536) / 64)
		end, function() return vector.create(0, 0, 0) end },
		{ "vector3f32", function() return t.vector3f32() end, function()
			return vector.create(math.random(-1000000, 1000000) / 1024, math.random(-1000000, 1000000) / 1024, math.random(-1000000, 1000000) / 1024)
		end, function() return vector.create(0, 0, 0) end },
		{ "direction", function() return t.direction(16) end, function() return vector.create(unit()) end, function() return vector.create(0, 1, 0) end },
		{ "rotation", function() return t.rotation(12) end, randomRotation, function() return R.CFrame.new() end },
		{ "cframe", function() return t.cframe(t.vector3(-1024, 1024, 1 / 64), t.rotation(12)) end, function()
			local q = randomRotation()
			return q + vector.create(math.random(-65536, 65536) / 64, math.random(-65536, 65536) / 64, math.random(-65536, 65536) / 64)
		end, function() return R.CFrame.new() end },
		{ "color3", function() return t.color3() end, function()
			return R.Color3.new(math.random(0, 255) / 255, math.random(0, 255) / 255, math.random(0, 255) / 255)
		end, function() return R.Color3.new(0, 0, 0) end },
		{ "robloxEnum", function() return t.enum(R.ShimEnum) end, function() return R.ShimEnumItems[math.random(1, 16)] end, function() return R.ShimEnumItems[1] end },
		{ "instance", function() return t.instance("BasePart") end, function() return INSTANCES[math.random(1, 8)] end, function() return INSTANCES[1] end },
		-- composites, each over an 8-bit int or a bool
		{ "optPresent", function() return t.optional(t.int(0, 255)) end, function() return math.random(0, 255) end, function() return 7 end },
		{ "optAbsent", function() return t.optional(t.int(0, 255)) end, function() return nil end, function() return nil end },
		{ "optRecord", function() return t.optional({ a = t.int(0, 255) }) end, function() return { a = math.random(0, 255) } end, function() return { a = 7 } end },
		{ "record1", function() return { a = t.int(0, 255) } end, function() return { a = math.random(0, 255) } end, function() return { a = 7 } end },
		{ "recordDeep4", function() return { a = { a = { a = { a = t.int(0, 255) } } } } end, function()
			return { a = { a = { a = { a = math.random(0, 255) } } } }
		end, function() return { a = { a = { a = { a = 7 } } } } end },
		{ "union2", function() return t.union({ A = { a = t.int(0, 255) }, B = { b = t.int(0, 255) } }) end, function()
			return if math.random() < 0.5 then { kind = "A", a = math.random(0, 255) } else { kind = "B", b = math.random(0, 255) }
		end, function() return { kind = "A", a = 7 } end },
		{ "arr0", function() return t.array(t.int(0, 255), 15) end, function() return {} end, function() return {} end },
		{ "arr1", function() return t.array(t.int(0, 255), 15) end, function() return { math.random(0, 255) } end, function() return { 7 } end },
		{ "arr4", function() return t.array(t.int(0, 255), 15) end, function()
			return { math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255) }
		end, function() return { 7, 7, 7, 7 } end },
		{ "map0", function() return t.map(t.int(0, 255), t.bool(), 15) end, function() return {} end, function() return {} end },
		{ "map1", function() return t.map(t.int(0, 255), t.bool(), 15) end, function() return { [math.random(0, 255)] = math.random() < 0.5 } end, function() return { [7] = false } end },
		{ "map4", function() return t.map(t.int(0, 255), t.bool(), 15) end, function()
			local m = {}
			while true do
				m[math.random(0, 255)] = math.random() < 0.5
				local n = 0
				for _ in m do n += 1 end
				if n == 4 then return m end
			end
		end, function() return { [1] = false, [2] = false, [3] = false, [4] = false } end },
		{ "mapStr4", function() return t.map(t.string(8), t.int(0, 255), 15) end, function()
			return { [word(4)] = math.random(0, 255), [word(4)] = math.random(0, 255), [word(4)] = math.random(0, 255), [word(4)] = math.random(0, 255) }
		end, function() return { aaaa = 7, aaab = 7, aaac = 7, aaad = 7 } end },
		{ "arrRecord4", function() return t.array({ a = t.int(0, 255), b = t.bool() }, 15) end, function()
			local a = {}
			for i = 1, 4 do a[i] = { a = math.random(0, 255), b = math.random() < 0.5 } end
			return a
		end, function()
			local a = {}
			for i = 1, 4 do a[i] = { a = 7, b = false } end
			return a
		end },
		{ "arrArr2", function() return t.array(t.array(t.bool(), 15), 15) end, function() return { {}, {} } end, function() return { {}, {} } end },
		{ "str200", function() return t.string(200) end, function() return word(200) end, function() return string.rep("a", 200) end },
		{ "buf200", function() return t.buffer(200) end, function() return buffer.fromstring(word(200)) end, function() return buffer.fromstring(string.rep("a", 200)) end },
	}

	local defs = {}
	local cases = {}
	local SIZES = { 1, 16 }
	local FORMS = { "row1", "runs", "colC", "colR" }

	local function recordOf(make, n)
		local r = {}
		for i = 1, n do r[string.format("f%02d", i)] = make() end
		return r
	end
	local function valueOf(gen, n)
		return function()
			local v = {}
			for i = 1, n do v[string.format("f%02d", i)] = gen() end
			return v
		end
	end

	for _, k in KINDS do
		local name, make, rand, const = k[1], k[2], k[3], k[4]
		for _, n in SIZES do
			local base = string.format("%s_%d", name, n)
			defs[base .. "_a"] = Lync.event({ from = "client", data = recordOf(make, n) })
			defs[base .. "_b"] = Lync.event({ from = "client", data = recordOf(make, n) })
			for _, form in FORMS do
				table.insert(cases, {
					name = base .. " " .. form, kind = name, n = n, form = form, a = base .. "_a", b = base .. "_b",
					value = valueOf(if form == "colC" then const else rand, n), cap = if form == "row1" then 1 else CAP,
				})
			end
		end
	end

	-- no payload (the n = 0 baseline of every form)
	defs.none_a = Lync.event({ from = "client" })
	defs.none_b = Lync.event({ from = "client" })
	for _, form in FORMS do
		table.insert(cases, { name = "none " .. form, kind = "none", n = 0, form = form, a = "none_a", b = "none_b", value = nil, cap = if form == "row1" then 1 else CAP })
	end

	-- busy-model and earlier-probe shapes (probes/inbound-budgets)
	local move6 = function()
		return { a = t.int(0, 1000), b = t.int(0, 1000), c = t.bool(), d = t.number(0, 1, 1 / 1024), e = t.enum({ "x", "y", "z" }), f = t.int(0, 255) }
	end
	defs.move6_a = Lync.event({ from = "client", data = move6() })
	defs.move6_b = Lync.event({ from = "client", data = move6() })
	local smOf = function()
		return { item = t.enum({ "sword", "bow", "staff" }), name = t.string(32), qty = t.int(1, 99), slot = t.optional(t.int(0, 15)) }
	end
	defs.sm_a = Lync.event({ from = "client", data = smOf() })
	defs.sm_b = Lync.event({ from = "client", data = smOf() })
	local randomMove6 = function()
		return { a = math.random(0, 1000), b = math.random(0, 1000), c = math.random() < 0.5, d = math.random(0, 1024) / 1024, e = ({ "x", "y", "z" })[math.random(1, 3)], f = math.random(0, 255) }
	end
	local randomSm = function()
		return { item = ({ "sword", "bow", "staff" })[math.random(1, 3)], name = word(8), qty = math.random(1, 99), slot = if math.random() < 0.5 then math.random(0, 15) else nil }
	end
	for _, form in FORMS do
		table.insert(cases, { name = "move6 " .. form, kind = "move6", n = 6, form = form, a = "move6_a", b = "move6_b",
			value = if form == "colC" then function() return { a = 5, b = 5, c = false, d = 0, e = "x", f = 0 } end else randomMove6, cap = if form == "row1" then 1 else CAP })
		table.insert(cases, { name = "sm " .. form, kind = "sm", n = 4, form = form, a = "sm_a", b = "sm_b",
			value = if form == "colC" then function() return { item = "bow", name = "abcdefgh", qty = 3, slot = 2 } end else randomSm, cap = if form == "row1" then 1 else CAP })
	end
	-- a 128-field bool record (draft 3.6's L = 128 reference), constant and random columns
	local bools128 = {}
	for i = 1, 128 do bools128[string.format("c%03d", i)] = t.bool() end
	defs.bools128_a = Lync.event({ from = "client", data = bools128 })
	table.insert(cases, { name = "bools128 colC", kind = "bools128", n = 128, form = "colC", a = "bools128_a", value = function()
		local v = {}
		for i = 1, 128 do v[string.format("c%03d", i)] = false end
		return v
	end, cap = 1024 })
	table.insert(cases, { name = "bools128 colR", kind = "bools128", n = 128, form = "colR", a = "bools128_a", value = function()
		local v = {}
		for i = 1, 128 do v[string.format("c%03d", i)] = math.random() < 0.5 end
		return v
	end, cap = 1024 })
	-- the review's shapes: 64 empty arrays and 32 empty maps per message (probes/review-3.6-runtime/probe.luau)
	local a64, m32 = {}, {}
	for i = 1, 64 do a64[string.format("a%02d", i)] = t.array(t.bool(), 255) end
	for i = 1, 32 do m32[string.format("m%02d", i)] = t.map(t.int(0, 255), t.bool(), 255) end
	defs.arr64_a = Lync.event({ from = "client", data = a64 })
	defs.arr64_b = Lync.event({ from = "client", data = table.clone(a64) })
	defs.map32_a = Lync.event({ from = "client", data = m32 })
	defs.map32_b = Lync.event({ from = "client", data = table.clone(m32) })
	local function emptyOf(prefix, count)
		return function()
			local v = {}
			for i = 1, count do v[string.format(prefix, i)] = {} end
			return v
		end
	end
	for _, form in FORMS do
		table.insert(cases, { name = "arr64empty " .. form, kind = "arr64empty", n = 64, form = form, a = "arr64_a", b = "arr64_b", value = emptyOf("a%02d", 64), cap = if form == "row1" then 1 else CAP })
		table.insert(cases, { name = "map32empty " .. form, kind = "map32empty", n = 32, form = form, a = "map32_a", b = "map32_b", value = emptyOf("m%02d", 32), cap = if form == "row1" then 1 else CAP })
	end
	-- long arrays in one message: per array element
	defs.arrBool_a = Lync.event({ from = "client", data = t.array(t.bool(), 65535) })
	defs.arrRec_a = Lync.event({ from = "client", data = t.array({ a = t.bool() }, 65535) })
	table.insert(cases, { name = "arrBool4096 single", kind = "arrBool", n = 1, form = "single", a = "arrBool_a", value = function()
		return table.create(4096, false)
	end, cap = 1 })
	table.insert(cases, { name = "arrRec4096 single", kind = "arrRec", n = 1, form = "single", a = "arrRec_a", value = function()
		local v = table.create(4096)
		for i = 1, 4096 do v[i] = { a = math.random() < 0.5 } end
		return v
	end, cap = 1 })
	-- one long string or buffer (the review's e + 4 frames): byte-linear decode
	defs.big_a = Lync.event({ from = "client", data = t.string(15900) })
	defs.bigbuf_a = Lync.event({ from = "client", data = t.buffer(15900) })
	table.insert(cases, { name = "string15900 single", kind = "bigString", n = 1, form = "single", a = "big_a", value = function() return word(15900) end, cap = 1 })
	table.insert(cases, { name = "buffer15900 single", kind = "bigBuffer", n = 1, form = "single", a = "bigbuf_a", value = function() return buffer.fromstring(word(15900)) end, cap = 1 })
	-- a mixed nested record: every kind of node once
	local function mixed()
		return {
			id = t.int(0, 65535),
			pos = t.vector3(-1024, 1024, 1 / 64),
			tag = t.optional(t.string(16)),
			act = t.union({ Move = { dir = t.direction(12), run = t.bool() }, Use = { slot = t.int(0, 15), target = t.optional(t.int(0, 1000)) } }),
			items = t.array({ k = t.enum({ "a", "b", "c" }), n = t.int(0, 99) }, 32),
			meta = t.map(t.int(0, 255), t.number(0, 1, 1 / 256), 16),
			inner = { a = t.bool(), b = { c = t.int(0, 7) } },
		}
	end
	defs.mixed_a = Lync.event({ from = "client", data = mixed() })
	defs.mixed_b = Lync.event({ from = "client", data = mixed() })
	local randomMixed = function()
		local items = {}
		for i = 1, math.random(0, 4) do items[i] = { k = ({ "a", "b", "c" })[math.random(1, 3)], n = math.random(0, 99) } end
		local meta = {}
		for _ = 1, math.random(0, 4) do meta[math.random(0, 255)] = math.random(0, 256) / 256 end
		return {
			id = math.random(0, 65535),
			pos = vector.create(math.random(-65536, 65536) / 64, math.random(-65536, 65536) / 64, 0),
			tag = if math.random() < 0.5 then word(6) else nil,
			act = if math.random() < 0.5 then { kind = "Move", dir = vector.create(unit()), run = math.random() < 0.5 } else { kind = "Use", slot = math.random(0, 15), target = if math.random() < 0.5 then math.random(0, 1000) else nil },
			items = items,
			meta = meta,
			inner = { a = math.random() < 0.5, b = { c = math.random(0, 7) } },
		}
	end
	for _, form in FORMS do
		table.insert(cases, { name = "mixed " .. form, kind = "mixed", n = 1, form = form, a = "mixed_a", b = "mixed_b",
			value = if form == "colC" then function()
				return { id = 1, pos = vector.create(0, 0, 0), act = { kind = "Use", slot = 1 }, items = {}, meta = {}, inner = { a = false, b = { c = 0 } } }
			end else randomMixed, cap = if form == "row1" then 1 else CAP })
	end

	return { schema = Lync.schema("bench", defs), cases = cases, KINDS = KINDS }
end
