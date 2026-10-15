--!strict
-- T3b: in-file, does enum1("a","b","c") stay exact when NOT observed through a singleton-expected reveal?
export type Codec<T> = { read _value: T, size: number }
local function make(size: number): any
	return { size = size }
end
local function enum1<T>(...: T): Codec<T>
	return make(1)
end
local function enumSet<S>(set: S): Codec<keyof<S>>
	return make(1)
end
local E1 = enum1("a", "b", "c")
local Es = enumSet({ a = true, b = true, c = true })
local bad1: typeof(E1._value) = "d" -- must fail if exact
local bad2: typeof(Es._value) = "d" -- must fail if exact
local function handler(v: typeof(E1._value))
	local _r: "REVEAL_param_E1" = v
end
local w: number = E1 -- reveal E1's own type via a mismatch
return { E1 = E1 }
