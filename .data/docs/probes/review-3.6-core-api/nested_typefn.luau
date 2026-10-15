--!strict
-- Runtime path: a type function builds field(path) overloads through records and optionals with dotted paths
-- (v5.md §3.4: "through records and optionals with dots"; arrays, maps and union variants not reachable).
-- The handle type is built inline, as in probes/design-3.6/field_handle_typefn.luau.
type function FieldOf(rec)
	local parts = {}
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
	local function walk(t: any, prefix: string)
		for key, prop in t:properties() do
			local name = tostring(key:value())
			local path = if prefix == "" then name else prefix .. "." .. name
			local inner = stripNil(prop.read)
			table.insert(parts, types.newfunction({ head = { types.any, types.singleton(path) } }, { head = { handleOf(inner) } }))
			if inner:is("table") and inner:indexer() == nil then walk(inner, path) end
		end
	end
	walk(rec, "")
	return types.intersectionof(table.unpack(parts))
end
type Kinded = { kind: "a", x: number } | { kind: "b", y: number }
type Shot = {
	origin: vector,
	hit: { part: number, at: vector }?,  -- record inside an optional
	meta: { tag: { level: number } },    -- two levels of records
	list: { { z: number } },             -- array: elements not reachable
	map: { [string]: { w: number } },    -- map: values not reachable
	variant: Kinded,                     -- union: variants not reachable
}
type View = { field: FieldOf<Shot> }
local v: View = nil :: any
v:field("origin"):derive({ fn = function() return vector.create(1, 2, 3) end, policy = "drop" })
v:field("hit.at"):derive({ fn = function() return vector.create(1, 2, 3) end, policy = "drop" })
v:field("hit.part"):derive({ fn = function() return 1 end, policy = "deliver" })
v:field("meta.tag.level"):derive({ fn = function() return 1 end, policy = "deliver" })
-- EXPECT errors below (lines 53-57)
v:field("hit.part"):derive({ fn = function() return vector.create(1, 2, 3) end, policy = "drop" }) -- wrong return
v:field("hit.nope") -- unknown nested path
v:field("list.z") -- through an array
v:field("variant.x") -- through a union
v:field("meta.tag.level"):derive({ fn = function() return 1 end, policy = "dorp" }) -- wrong option literal
