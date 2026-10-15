--!strict
-- (e) in Lync's own module: the runtime path's define returns View<S>; the game's script never writes the type function.
type function FieldOf(rec)
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
	local parts = {}
	walk(rec, "", function(path, inner)
		table.insert(parts, types.newfunction({ head = { types.any, types.singleton(path) } }, { head = { handleOf(inner) } },
			{ types.generic("G" .. tostring(#parts + 1)) }))
	end)
	return types.intersectionof(table.unpack(parts))
end
export type View<S> = { field: FieldOf<S> }
local Lync = {}
function Lync.define<S>(schema: S): View<S>
	return nil :: any
end
return Lync
