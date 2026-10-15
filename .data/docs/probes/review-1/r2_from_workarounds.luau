--!strict
-- R2: ways to keep `from` exact. Each REVEAL line prints what the checker inferred.
export type Codec<T> = { read _value: T }
local function make(): any return {} end
local int: Codec<number> = make()

-- V3: a generic for the field itself
local function v3<F, D>(def: { from: F, data: D }): F return make() end
local a = v3({ from = "client", data = int })
local _ra: "REVEAL_v3" = a

-- V2: overloaded (intersection of generic functions) selected by the literal
type Overloads = (<D>(def: { from: "client", data: D }) -> "C") & (<D>(def: { from: "server", data: D }) -> "S")
local v2: Overloads = make()
local b = v2({ from = "client", data = int })
local _rb: "REVEAL_v2_client" = b
local c = v2({ from = "server", data = int })
local _rc: "REVEAL_v2_server" = c
local d = v2({ from = "clinet", data = int }) -- typo: should be an error
local _rd: "REVEAL_v2_typo" = d

-- V5: expected type with a union field, then a type function reads it
type function FromTag(d)
	local f = d:readproperty(types.singleton("from"))
	if f and f:is("singleton") then return types.singleton(`singleton:{f:value()}`) end
	return types.singleton(`tag:{f and f.tag}`)
end
local function v5<D>(def: D & { from: "client" | "server" }): FromTag<D> return make() end
local e = v5({ from = "client", data = int })
local _re: "REVEAL_v5" = e
