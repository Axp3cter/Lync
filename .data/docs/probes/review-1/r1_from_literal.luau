--!strict
-- R1: does a string literal inside an option table keep its singleton type
-- when the table is passed to a generic `<D>(def: D)`?
export type Codec<T> = { read _value: T }
local function make(): any return {} end
local t = { int = function(a: number?, b: number?): Codec<number> return make() end }

local function identity<D>(def: D): D return def end

local e1 = identity({ from = "client", data = t.int(0, 3) })
local _r1: "REVEAL_e1" = e1

-- what a type function sees for `from`
type function FromTag(d)
	local f = d:readproperty(types.singleton("from"))
	if f == nil then error("no from") end
	if f:is("singleton") then return types.singleton(`singleton:{f:value()}`) end
	return types.singleton(`tag:{f.tag}`)
end
local function event<D>(def: D): FromTag<D> return make() end
local e2 = event({ from = "client", data = t.int(0, 3) })
local _r2: "REVEAL_e2" = e2
local e3 = event({ from = "server" :: "server", data = t.int(0, 3) })
local _r3: "REVEAL_e3" = e3
-- timestamped = true, lane = "unreliable": same question for booleans
type function TsTag(d)
	local f = d:readproperty(types.singleton("timestamped"))
	if f == nil then error("no ts") end
	if f:is("singleton") then return types.singleton(`singleton:{tostring(f:value())}`) end
	return types.singleton(`tag:{f.tag}`)
end
local function event2<D>(def: D): TsTag<D> return make() end
local e4 = event2({ from = "client", timestamped = true })
local _r4: "REVEAL_e4" = e4
