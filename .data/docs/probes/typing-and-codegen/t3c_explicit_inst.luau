--!strict
-- T3c: explicit type instantiation syntax f<<T>>(...)  (RFC) in 0.740?
export type Codec<T> = { read _value: T, size: number }
local function make(size: number): any
	return { size = size }
end
local function enum1<T>(...: T): Codec<T>
	return make(1)
end
local E = enum1<<"a" | "b" | "c">>("a", "b", "c")
local bad: typeof(E._value) = "d" -- must fail
local E2 = enum1<<"a" | "b">>("a", "z") -- must fail: "z" not a member
return { E = E }
