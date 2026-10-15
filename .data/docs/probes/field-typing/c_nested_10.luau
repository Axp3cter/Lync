--!strict
-- (c) Split by nesting level: field(name) overloads per record over its direct children only;
-- v:field("hit"):field("at") for a nested path. Top level here has 8 keys, 10 paths in all.
type function NodeOf(rec)
	local function handleOf(t)
		return types.newtable({ [types.singleton("derive")] = types.newfunction(
			{ head = { types.any, types.newtable({
				[types.singleton("fn")] = types.newfunction({}, { head = { types.optional(t) } }),
				[types.singleton("policy")] = types.unionof(types.singleton("drop"), types.singleton("deliver")),
			}) } }, {}) })
	end
	local function stripNil(t: any): any
		if t:is("union") then
			local rest = {}
			local hadNil = false
			for _, c in t:components() do
				if c:is("nil") then hadNil = true else table.insert(rest, c) end
			end
			if hadNil and #rest == 1 then return rest[1] end
		end
		return t
	end
	-- calls each(path, inner) for every path through records and optionals
	local function walk(t: any, prefix: string, each)
		for key, prop in t:properties() do
			local name = tostring(key:value())
			local path = if prefix == "" then name else prefix .. "." .. name
			local inner = stripNil(prop.read)
			each(path, inner)
			if inner:is("table") and inner:indexer() == nil then walk(inner, path, each) end
		end
	end
	local function node(t: any): any
		local parts = {}
		for key, prop in t:properties() do
			local inner = stripNil(prop.read)
			local h = handleOf(inner)
			if inner:is("table") and inner:indexer() == nil then
				h:setproperty(types.singleton("field"), node(inner))
			end
			table.insert(parts, types.newfunction({ head = { types.any, types.singleton(tostring(key:value())) } }, { head = { h } }))
		end
		return types.intersectionof(table.unpack(parts))
	end
	return node(rec)
end
type Shot = { f1: vector, f2: string, f3: number, f4: vector, f5: string, f6: number, f7: vector, hit: { part: number, at: vector }? }
type View = { field: NodeOf<Shot> }
local v: View = nil :: any
local h2 = v:field("f2") -- inferred type: see run.out (--annotate)
v:field("f3"):derive({ fn = function() return 1 end, policy = "drop" })
v:field("hit"):field("at"):derive({ fn = function() return vector.create(1, 2, 3) end, policy = "deliver" })
v:field("f7"):derive({ fn = function() return nil end, policy = "drop" })
local _exact: { derive: (any, { fn: () -> string?, policy: "drop" | "deliver" }) -> () } = v:field("f2")
-- EXPECT an error on each line below
local _wrongType: { derive: (any, { fn: () -> number?, policy: "drop" | "deliver" }) -> () } = v:field("f2") -- f2 is a string handle
v:field("hit"):field("part"):derive({ fn = function() return vector.create(1, 2, 3) end, policy = "drop" }) -- wrong return
local _wrongPath = v:field("nope") -- unknown path
v:field("f3"):derive({ fn = function() return 1 end, policy = "dorp" }) -- wrong option
return h2
