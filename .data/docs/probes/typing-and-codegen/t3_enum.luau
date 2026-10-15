--!strict
-- T3 probe: which call syntax yields exactly "a" | "b" | "c"
export type Codec<T> = { read _value: T, size: number }
local function make(size: number): any
	return { size = size }
end

type function Values(s) -- union of an array type's element / of a table's property value types
	local idx = s:indexer()
	if idx then
		return idx.readresult
	end
	local parts = {}
	for _, p in s:properties() do
		table.insert(parts, p.read)
	end
	return types.unionof(table.unpack(parts))
end

-- 1. generic variadic, one T
local function enum1<T>(...: T): Codec<T>
	return make(1)
end
local E1 = enum1("a", "b", "c")
local _r1: "R1_variadic_T" = E1._value

-- 1b. generic pack
local function enum1b<T...>(...: T...): Codec<T...>
	return make(1)
end
local E1b = enum1b("a", "b", "c")
local _r1b: "R1b_pack" = E1b._value

-- 2. array literal, generic element
local function enum2<T>(list: { T }): Codec<T>
	return make(1)
end
local E2 = enum2({ "a", "b", "c" })
local _r2: "R2_array_T" = E2._value

-- 2b. array literal, raw S + type function
local function enum2b<S>(list: S): Codec<Values<S>>
	return make(1)
end
local E2b = enum2b({ "a", "b", "c" })
local _r2b: "R2b_array_S" = E2b._value

-- 3. set literal + keyof
local function enum3<S>(set: S): Codec<keyof<S>>
	return make(1)
end
local E3 = enum3({ a = true, b = true, c = true })
local _r3: "R3_keyof" = E3._value

-- 3b. names as values in a keyed table (a = "a")
local E3b = enum2b({ a = "a", b = "b", c = "c" })
local _r3b: "R3b_values" = E3b._value

-- 4a. cast at the call
local E4a = enum1("a", "b", "c") :: Codec<"a" | "b" | "c">
local _r4a: "R4a_cast" = E4a._value
-- 4b. annotation at the binding
local E4b: Codec<"a" | "b" | "c"> = enum1("a", "b", "c")
local _r4b: "R4b_annot" = E4b._value
-- 4c. per-argument casts
local E4c = enum1("a" :: "a", "b" :: "b", "c" :: "c")
local _r4c: "R4c_argcast" = E4c._value
-- 4d. typed array argument
local E4d = enum2({ "a", "b", "c" } :: { "a" | "b" | "c" })
local _r4d: "R4d_arrcast" = E4d._value
-- 4e. cast to Codec but WRONG member list: does the cast check it? (bad: "z" not passed)
local E4e = enum1("a", "b") :: Codec<"a" | "z">
-- 4f. annotation with wrong list
local E4f: Codec<"a" | "z"> = enum1("a", "b")

-- 5. const locals
const A = "a"
const B = "b"
const C = "c"
local _r5a: "R5_const_type" = A
local E5 = enum1(A, B, C)
local _r5: "R5_const_enum" = E5._value
local E5b = enum2({ A, B, C })
local _r5b: "R5b_const_array" = E5b._value

-- exactness: misspelled member must be rejected, correct accepted
local ok3: typeof(E3._value) = "a"
local bad3: typeof(E3._value) = "d" -- must fail
return nil
