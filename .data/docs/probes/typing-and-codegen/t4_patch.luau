--!strict
-- T4 probe: Patch<T> makes every field optional; misspelled key / wrong value type rejected?
type function Patch(t)
	if not t:is("table") then
		error(`Patch expects a record type, got {t.tag}`)
	end
	local out = types.newtable()
	for key, prop in t:properties() do
		out:setproperty(key, types.optional(prop.read))
	end
	return out
end

type Rec = { hp: number, name: string, pos: { x: number, y: number }, tag: string? }
type P = Patch<Rec>
local _reveal: "REVEAL_T4" = (nil :: any) :: P

local ok1: P = {}
local ok2: P = { hp = 5 }
local ok3: P = { name = "n", pos = { x = 1, y = 2 } }
local bad_type: P = { hp = "five" } -- must fail
local bad_key: P = { hpp = 5 } -- misspelled: must fail?
local bad_key2: P = { hp = 5, nmae = "x" } -- misspelled alongside a valid key
local bad_nested: P = { pos = { x = 1 } } -- nested still exact (shallow patch)

-- the same through a function parameter (how an update API would take it)
local function update(p: P) end
update({ hpp = 5 }) -- misspelled: must fail?
update({ hp = "x" }) -- must fail
-- via generic: update<T>(state: T, p: Patch<T>)
local function update2<T>(state: T, p: Patch<T>) end
local state: Rec = { hp = 1, name = "a", pos = { x = 0, y = 0 } }
update2(state, { hpp = 5 }) -- must fail?
update2(state, { hp = "x" }) -- must fail

-- a table type with all-optional fields: is a misspelled key rejected for a plain handwritten type?
type Hand = { hp: number?, name: string? }
local bad_hand: Hand = { hpp = 5 }
return nil
