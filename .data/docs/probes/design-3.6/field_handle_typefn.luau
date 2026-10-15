--!strict
type Field<T> = { derive: (self: Field<T>, options: { fn: () -> T?, policy: "drop" | "deliver" }) -> () }
type function FieldOf(rec, handle)
	-- one overload per top-level field: (self: any, path: "<name>") -> handle<T>
	local parts = {}
	for key, prop in rec:properties() do
		local t = prop.read
		local fieldType = types.newtable({ [types.singleton("derive")] = types.newfunction(
			{ head = { types.any, types.newtable({
				[types.singleton("fn")] = types.newfunction({}, { head = { types.optional(t) } }),
				[types.singleton("policy")] = types.unionof(types.singleton("drop"), types.singleton("deliver")),
			}) } }, {}) })
		table.insert(parts, types.newfunction({ head = { types.any, key } }, { head = { fieldType } }))
	end
	return types.intersectionof(table.unpack(parts))
end
type Shot = { landing: vector, flight: number }
type View = { field: FieldOf<Shot, Field<any>> }
local v: View = nil :: any
v:field("landing"):derive({ fn = function() return vector.create(1, 2, 3) end, policy = "drop" })
v:field("flight"):derive({ fn = function() return 1 end, policy = "deliver" })
v:field("flight"):derive({ fn = function() return vector.create(1, 2, 3) end, policy = "drop" }) -- EXPECT error
v:field("nope") -- EXPECT error
