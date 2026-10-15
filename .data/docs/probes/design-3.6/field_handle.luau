--!strict
type Shot = { landing: vector, flight: number, target: number }
type Field<D, T> = {
	derive: (self: Field<D, T>, options: { fn: (string, D) -> T?, tolerance: number, policy: "drop" | "deliver" }) -> (),
	refers: (self: Field<D, T>, collection: Collection<T>) -> (),
}
type Collection<K> = { get: (self: Collection<K>, key: K) -> {}? }
type View = {
	field: ((self: View, path: "landing") -> Field<Shot, vector>)
		& ((self: View, path: "flight") -> Field<Shot, number>)
		& ((self: View, path: "target") -> Field<Shot, number>),
}
local v: View = nil :: any
local fighters: Collection<number> = nil :: any
local names: Collection<string> = nil :: any
v:field("landing"):derive({ fn = function(p, s) return s.landing end, tolerance = 0.25, policy = "deliver" })
v:field("flight"):derive({ fn = function(p, s) return s.flight end, tolerance = 0, policy = "drop" })
v:field("target"):refers(fighters)
-- EXPECT errors below
v:field("flight"):derive({ fn = function(p, s) return s.landing end, tolerance = 0, policy = "drop" })
v:field("flight"):derive({ fn = function(p, s) return s.flight end, tolerance = 0, policy = "dorp" })
v:field("target"):refers(names)
v:field("nope")
