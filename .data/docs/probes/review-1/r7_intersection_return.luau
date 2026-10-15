--!strict
-- R7: `D & { from: ... }` parameter; does the return type decide whether the call checks?
export type Codec<T> = { read _value: T }
local function make(): any return {} end
local int: Codec<number> = make()
type function Field(d, name)
	local f = d:readproperty(name)
	if f == nil then error("missing") end
	return f:readproperty(types.singleton("_value")) or types.unknown
end
type function FromOf(d)
	return d:readproperty(types.singleton("from")) or types.never
end
local function r1<D>(def: D & { from: "client" | "server" }): D return make() end
local function r2<D>(def: D & { from: "client" | "server" }): Field<D, "reply"> return make() end
local function r3<D>(def: D & { from: "client" | "server" }): { read v: Field<D, "reply"> } return make() end
local function r4<D>(def: D & { from: "client" | "server" }): FromOf<D> return make() end
local _1 = r1({ from = "client", data = int, reply = int })
local _2 = r2({ from = "client", data = int, reply = int })
local _3 = r3({ from = "client", data = int, reply = int })
local _4 = r4({ from = "client", data = int, reply = int })
