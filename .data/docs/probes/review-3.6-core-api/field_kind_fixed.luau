--!strict
-- The fix: the shard emits each handle's methods from the field's codec, not from its Luau type; the key type of
-- refers/about is the collection's key type K, separate from the field's type T (T = K, K?, or { K }).
type Data = { origin: vector, dir: vector, coins: number, target: number? }
type Collection<K> = { get: (self: Collection<K>, key: K) -> {}? }
type Policy = "drop" | "deliver"
type Within<D, T> = (self: any, options: { reference: (any, D) -> T?, maxDistance: number, policy: Policy }) -> ()
type PositionField<D> = { within: Within<D, vector> }                       -- t.vector3: within, maxRate, derive, series
type DirectionField<D> = { within: Within<D, vector>, aim: (self: any) -> () } -- t.direction adds aim
type SignedIntField<D> = { within: Within<D, number> }                     -- t.int with negative values: no maxTotal
type KeyField<K> = { refers: (self: any, collection: Collection<K>) -> () } -- t.optional(key codec)
type View = {
	field: ((self: View, path: "origin") -> PositionField<Data>)
		& ((self: View, path: "dir") -> DirectionField<Data>)
		& ((self: View, path: "coins") -> SignedIntField<Data>)
		& ((self: View, path: "target") -> KeyField<number>),
}
local v: View = nil :: any
local fighters: Collection<number> = nil :: any
local names: Collection<string> = nil :: any
v:field("dir"):aim()
v:field("target"):refers(fighters)
-- EXPECT errors below (lines 24-26)
v:field("origin"):aim()
v:field("coins"):maxTotal({ cap = 5000, seconds = 600, policy = "drop" })
v:field("target"):refers(names)
