--!strict
-- v5.md §3.4 / v5-checks.md §8.6: handles are Field<D, T>, T the field's Luau type; aim "present only where T is a
-- codec they take". Schema: data = { origin = t.vector3(-2048, 2048, 1/32), dir = t.direction(11),
--   coins = t.int(-100, 100), target = t.optional(t.int(1, 2^40)) }; fighters' key t.int(1, 2^40).
type Data = { origin: vector, dir: vector, coins: number, target: number? }
type Collection<K> = { get: (self: Collection<K>, key: K) -> {}? }
type Field<D, T> = {
	within: (self: Field<D, T>, options: { reference: (any, D) -> T?, maxDistance: number, policy: "drop" | "deliver" }) -> (),
	maxTotal: (self: Field<D, T>, options: { cap: number, seconds: number, policy: "drop" | "deliver" }) -> (),
	aim: (self: Field<D, T>) -> (),
	refers: (self: Field<D, T>, collection: Collection<T>) -> (),
}
type View = {
	field: ((self: View, path: "origin") -> Field<Data, vector>)
		& ((self: View, path: "dir") -> Field<Data, vector>)
		& ((self: View, path: "coins") -> Field<Data, number>)
		& ((self: View, path: "target") -> Field<Data, number?>),
}
local v: View = nil :: any
local fighters: Collection<number> = nil :: any
-- Wrong usages that v5-checks.md makes run-time fieldKind errors; each typechecks below (no error expected by the
-- Field<D, T> shape, which is the finding):
v:field("origin"):aim() -- t.vector3 is a position, not an aim codec (v5-checks.md §8.2)
v:field("coins"):maxTotal({ cap = 5000, seconds = 600, policy = "drop" }) -- negative values: fieldKind (§4.2)
-- A correct usage that the shape rejects: refers on t.optional of the key codec (v5-integrity.md §8 allows it)
v:field("target"):refers(fighters) -- error on both solvers: Collection<number> is not Collection<number?>
