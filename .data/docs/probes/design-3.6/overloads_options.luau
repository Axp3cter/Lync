--!strict
type Shot = { landing: vector, flight: number }
type O<T> = { fn: (string, Shot) -> T?, tolerance: number }
type P<T> = { fn: (string, Shot) -> T?, policy: "drop" | "deliver" }
type L = { tolerance: number, policy: "drop" | "deliver" }
type View = {
	a: ((self: View, path: "landing", o: O<vector>) -> ()) & ((self: View, path: "flight", o: O<number>) -> ()),
	b: ((self: View, path: "landing", o: P<vector>) -> ()) & ((self: View, path: "flight", o: P<number>) -> ()),
	c: ((self: View, path: "landing", o: L) -> ()) & ((self: View, path: "flight", o: L) -> ()),
}
local v: View = nil :: any
v:a("flight", { fn = function(p, s) return s.flight end, tolerance = 0 }) -- line 12: lambda, no literal
v:b("flight", { fn = function(p, s) return s.flight end, policy = "drop" }) -- line 13: lambda + literal
v:c("flight", { tolerance = 0, policy = "drop" }) -- line 14: literal only
