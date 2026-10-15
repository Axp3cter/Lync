--!strict
-- (b) in Lync's own module: define returns View<S> with fields: FieldsOf<S>.
type function FieldsOf(rec)
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
	local props = {}
	walk(rec, "", function(path, inner) props[types.singleton(path)] = handleOf(inner) end)
	return types.newtable(props)
end
export type View<S> = { fields: FieldsOf<S> }
local Lync = {}
function Lync.define<S>(schema: S): View<S>
	return nil :: any
end
return Lync
