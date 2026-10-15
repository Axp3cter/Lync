--!strict
-- R3: a literal-generic `patch` method (T4b) inside a definition that a side-selecting type
-- function (T6-G) walks. Rec is concrete here, so only the generic method is under test.
type function StrictPatch(p, t)
	if not p:is("table") then error(`patch must be a table, got {p.tag}`) end
	for key, prop in p:properties() do
		local target = t:readproperty(key)
		if not target then error(`unknown field '{key:value()}' in patch`) end
		if not prop.read:issubtypeof(target) then error(`field '{key:value()}' has the wrong type`) end
	end
	return p
end
type function SelectSide(schema, side)
	local out = types.newtable()
	for key, prop in schema:properties() do
		out:setproperty(key, prop.read:readproperty(side))
	end
	return out
end
type Rec = { health: number, name: string }
type ServerCollection<T> = {
	set: (self: ServerCollection<T>, id: number, value: T) -> (),
	patch: <P>(self: ServerCollection<T>, id: number, p: P) -> StrictPatch<P, T>,
}
type Def = { read _server: ServerCollection<Rec> }

-- (a) the collection type used directly: works (T4b)
local direct: ServerCollection<Rec> = nil :: any
direct:patch(1, { health = 1 })
direct:patch(1, { healht = 1 }) -- must fail

-- (b) the same type selected through the view type function
local schema: { fighters: Def } = nil :: any
local function server<S>(s: S): SelectSide<S, "_server"> return nil :: any end
local Net = server(schema)
Net.fighters:set(1, { health = 1, name = "n" })
Net.fighters:patch(1, { health = 1 })
Net.fighters:patch(1, { healht = 1 }) -- must fail
