--!strict
-- Runtime path: a type function builds field(path) overloads through records and optionals with dotted paths.
-- Arrays, maps and union variants are not reachable (v5.md §3.4). Field<T> is the handle type.
type Field<T> = { derive: (self: Field<T>, options: { fn: () -> T?, policy: "drop" | "deliver" }) -> () }
type function stripNil(t)
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
type function isRecord(t)
	-- a plain table type with properties and no indexer (arrays and maps have an indexer)
	return t:is("table") and t:indexer() == nil
end
type function FieldOf(rec, handle)
	local parts = {}
	local function walk(t, prefix)
		for key, prop in t:properties() do
			local ft = prop.read
			local path = if prefix == "" then key:value() else prefix .. "." .. key:value()
			local inner = stripNil(ft)
			table.insert(parts, types.newfunction({ head = { types.any, types.singleton(path) } }, { head = { handle(inner) } }))
			if isRecord(inner) then walk(inner, path) end
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
type View = { field: FieldOf<Shot, Field> }
local v: View = nil :: any
v:field("origin"):derive({ fn = function() return vector.create(1, 2, 3) end, policy = "drop" })
v:field("hit.at"):derive({ fn = function() return vector.create(1, 2, 3) end, policy = "drop" })
v:field("hit.part"):derive({ fn = function() return 1 end, policy = "deliver" })
v:field("meta.tag.level"):derive({ fn = function() return 1 end, policy = "deliver" })
-- EXPECT errors below
v:field("hit.part"):derive({ fn = function() return vector.create(1, 2, 3) end, policy = "drop" }) -- wrong return
v:field("hit.nope") -- unknown nested path
v:field("list.z") -- through an array
v:field("variant.x") -- through a union
v:field("meta.tag.level"):derive({ fn = function() return 1 end, policy = "dorp" }) -- wrong option literal
