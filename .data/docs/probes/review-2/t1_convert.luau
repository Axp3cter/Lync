--!strict
-- review-2 t1: §3.3/§7.1 `t.convert(base, decode, encode)` "typed both ways". Do the lambdas'
-- parameters infer, and is U taken from decode's return, with no annotations?
export type Codec<T> = { read _value: T }
local function make(): any return {} end
type function Infer(s)
	if s:is("table") then
		local v = s:readproperty(types.singleton("_value"))
		if v then return v end
		local out = types.newtable()
		for key, prop in s:properties() do out:setproperty(key, Infer(prop.read)) end
		return out
	end
	return types.unknown
end
local int: Codec<number> = make()
type UDim = { Scale: number, Offset: number }
local function udimNew(s: number, o: number): UDim return { Scale = s, Offset = o } end

-- (a) base is a leaf codec: structural Codec<B>
local function convertA<B, U>(base: Codec<B>, decode: (B) -> U, encode: (U) -> B): Codec<U> return make() end
local a = convertA(int, function(n) return udimNew(n, 0) end, function(u) return u.Scale end)
local _ra: "REVEAL_a" = a

-- (b) base is a plain record table (the §3.4 record form): needs Infer<S>
local function convertB<S, U>(base: S, decode: (Infer<S>) -> U, encode: (U) -> Infer<S>): Codec<U> return make() end
local b = convertB({ scale = int, offset = int }, function(w) return udimNew(w.scale, w.offset) end, function(u)
	return { scale = u.Scale, offset = u.Offset }
end)
local _rb: "REVEAL_b" = b
local _bad = convertB({ scale = int }, function(w) return udimNew(w.scael, 0) end, function(u) return { scale = 1 } end) -- typo in decode: caught?
