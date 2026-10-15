--!strict
-- T4b: can a type function over the literal's own type reject unknown keys?
type function StrictPatch(p, t)
	-- p: the argument's inferred type; t: the record type
	if not p:is("table") then
		error(`patch must be a table, got {p.tag}`)
	end
	for key, prop in p:properties() do
		local target = t:readproperty(key)
		if not target then
			error(`unknown field '{key:value()}' in patch`)
		end
		if not prop.read:issubtypeof(target) then
			error(`field '{key:value()}' has the wrong type`)
		end
	end
	return p
end
type Rec = { hp: number, name: string, pos: { x: number, y: number } }

-- (a) check through the return type
local function updateA<P>(p: P): StrictPatch<P, Rec>
	return p :: any
end
updateA({ hp = 5 }) -- ok
updateA({ hpp = 5 }) -- must fail
updateA({ hp = "x" }) -- must fail

-- (b) check through the parameter type itself
local function updateB<P>(p: StrictPatch<P, Rec>) end
updateB({ hp = 5 }) -- ok
updateB({ hpp = 5 }) -- must fail

-- (c) method on a generic state type
type Store<T> = { patch: <P>(self: Store<T>, p: P) -> StrictPatch<P, T> }
local store: Store<Rec> = nil :: any
store:patch({ name = "x" }) -- ok
store:patch({ nmae = "x" }) -- must fail
store:patch({ name = 5 }) -- must fail
return nil
