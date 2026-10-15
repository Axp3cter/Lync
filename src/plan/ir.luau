--!strict

--[=[
	Ir

	The planned form of a schema: every codec with its widths, every definition with its options
	resolved and its worst-case sizes, and the namespace's id spaces and hash.

	The planner builds it once per schema and freezes it; the interpreter, the transport and the
	compiler read it. This module holds types only.

	Indices that travel on the wire (enum items, union variants, ids) are 0-based.
]=]


-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../wire/bits")


-- Module ------------------------------------------------------------------------------------------

local Ir = {}


-- Types -------------------------------------------------------------------------------------------

--[=[
	A codec of v5.md §3.3. `width` is the bits of the code its single-row encoding writes: of the
	value for `int`, `number` and `angle`, of the length for `string` and `buffer`, of the count for
	`array` and `map`, of the index for `enum` and `union`.
]=]
export type Codec =
	| { kind: "bool" }
	| { kind: "int", min: number, max: number, width: number }
	| { kind: "varint" }
	| NumberCodec
	| { kind: "f32" }
	| { kind: "f64" }
	| { kind: "angle", step: number, steps: number, width: number }
	| { kind: "string", max: number, width: number }
	| { kind: "buffer", max: number, width: number }
	| { kind: "vector3", axis: NumberCodec }
	| { kind: "vector3f32" }
	| { kind: "direction", bits: number }
	| { kind: "rotation", bits: number }
	| { kind: "cframe", position: Codec, rotation: Codec }
	| { kind: "color3" }
	| { kind: "enum", items: { string }, index: { [string]: number }, width: number }
	| { kind: "robloxEnum", name: string, byValue: { [number]: EnumItem } }
	| { kind: "instance", class: string? }
	| { kind: "optional", inner: Codec }
	| { kind: "array", inner: Codec, max: number, width: number }
	| { kind: "map", key: Codec, value: Codec, max: number, width: number }
	| { kind: "union", variants: { Variant }, byName: { [string]: number }, width: number }
	| { kind: "record", fields: { Field } }
	| {
		kind: "custom",
		name: string,
		version: number,
		maxBits: number,
		maxBytes: number,
		encode: (Bits.Writer, any) -> (),
		decode: (Bits.Reader) -> (any, number),
	}
	| { kind: "convert", base: Codec, decode: (any) -> any, encode: (any) -> any }


--- A `t.number`, and each axis of a `t.vector3`.
export type NumberCodec = {
	kind: "number",
	min: number,
	max: number,
	step: number,
	steps: number,
	width: number,
}


--- A record field, in name order; `newest` marks a collection field declared with `:newest()`.
export type Field = { name: string, codec: Codec, newest: boolean }


--- A union variant, in name order; `record` is a `record` codec.
export type Variant = { name: string, record: Codec }


--[=[
	A planned definition. Options a kind does not take hold 0 (`timeout`, `maxRecords`,
	`priority`) or nil.

	@field dataMaxBits  the worst-case bits of `data` in single-row encoding, 0 without `data`
	@field dataMaxTail  the worst-case tail bytes of `data`
	@field replyMaxBits the worst-case bits of `reply`, 0 without `reply`
	@field replyMaxTail the worst-case tail bytes of `reply`
	@field hasInstances whether `data` or `reply` can hold a `t.instance`
	@field line         where the definition's constructor was called
	@field source       the source of that call
]=]
export type Definition = {
	name: string,
	kind: "event" | "request" | "collection",
	from: "client" | "server",
	lane: "reliable" | "unreliable",
	data: Codec?,
	reply: Codec?,
	key: Codec?,
	limit: { perSecond: number, burst: number }?,
	timeout: number,
	maxRecords: number,
	priority: number,
	reliableRate: number?,
	dataMaxBits: number,
	dataMaxTail: number,
	replyMaxBits: number,
	replyMaxTail: number,
	hasInstances: boolean,
	line: number,
	source: string,
}


--- One id in an id space (v5.md §4.6): a definition's event, or a request's ask or answer.
export type Entry = { definition: Definition, role: "event" | "ask" | "answer", id: number }


--[=[
	A planned schema.

	@field definitions     every definition, in name order
	@field byName          every definition by its name
	@field up              the up id space; element i has id i - 1
	@field down            the down id space
	@field collections     the collection id space
	@field upWidth         the bits of an up id
	@field downWidth       the bits of a down id
	@field collectionWidth the bits of a collection id
	@field serialization   the canonical serialization of v5.md §4.7
	@field hashLow         the low u32 of the schema hash
	@field hashHigh        the high u32 of the schema hash
	@field line            where `Lync.schema` was called
	@field source          the source of that call
]=]
export type Namespace = {
	name: string,
	definitions: { Definition },
	byName: { [string]: Definition },
	up: { Entry },
	down: { Entry },
	collections: { Definition },
	upWidth: number,
	downWidth: number,
	collectionWidth: number,
	serialization: buffer,
	hashLow: number,
	hashHigh: number,
	line: number,
	source: string,
}


return table.freeze(Ir)
