--!nocheck
--!nolint UnknownGlobal

--[=[
	Types

	The types of the runtime path (v5.md §3.2): codecs, the `t` table, definitions, schemas, and
	the side-split views a schema gives each side.

	Exact types come from type functions, which only the new solver runs. This module is
	`--!nocheck` so the old solver, which rejects type functions and `read` fields, reports
	nothing here; files that use these types then see error types under it (probes T7), while the
	generated path (milestone 3) gives concrete types on both solvers.

	No type function calls `error()`: an error type flowing into a view crashes luau-analyze and
	luau-lsp (review-2 M3). A problem becomes a marker type, a string singleton naming it.

	The views exist as types only in milestone 1; their runtime is milestone 2.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Ir = require("./plan/ir")

-- Module ------------------------------------------------------------------------------------------

local Types = {}

-- Types -------------------------------------------------------------------------------------------

--- A codec for values of type `T`; `_value` exists only in the type.
export type Codec<T> = {
	read _value: T,
	newest: (self: Codec<T>) -> Codec<T>,
}

--[=[
	The value type of a codec, or of a record of codecs.

	@param  codec a `Codec<T>`, or a table type whose properties are codecs or records
	@return `T`, a record type of the properties' value types, or a marker string when `codec` is
	        neither
]=]
export type function Infer(codec)
	if not codec:is("table") then
		return types.singleton("[Lync] expected a codec or a record of codecs")
	end

	local value = codec:readproperty(types.singleton("_value"))
	if value ~= nil then
		return value
	end

	local record = types.newtable()
	for key, property in codec:properties() do
		if property.read == nil then
			return types.singleton("[Lync] expected a readable record field")
		end

		record:setproperty(key, Infer(property.read))
	end

	return record
end

--[=[
	The value type of a union: one record per variant, each with its name as `kind`.

	@param  variants a table type of records by variant name
	@return the union of the variants' record types
]=]
export type function Tagged(variants)
	if not variants:is("table") then
		return types.singleton("[Lync] expected a table of variant records")
	end

	local members = {}
	for key, property in variants:properties() do
		local variant = types.newtable()
		variant:setproperty(types.singleton("kind"), key)

		local record = Infer(property.read)
		if record:is("table") then
			for field, value in record:properties() do
				variant:setproperty(field, value.read)
			end
		end

		table.insert(members, variant)
	end

	if #members == 0 then
		return types.never
	end

	return types.unionof(table.unpack(members))
end

--[=[
	A record type with every field optional, as `patch` takes it.

	@param  record a record type
	@return the record with each field's type made optional
]=]
export type function Partial(record)
	if not record:is("table") then
		return record
	end

	local partial = types.newtable()
	for key, property in record:properties() do
		partial:setproperty(key, types.optional(property.read))
	end

	return partial
end

--- The custom codec's specification (v5.md §8).
export type CustomSpec<V> = {
	encode: (writer: any, value: V) -> (),
	decode: (reader: any) -> (V, number),
	maxBits: number?,
	maxBytes: number?,
	luauType: string?,
	tsType: string?,
	name: string,
	version: number,
}

--- The `t` table: every codec constructor of v5.md §3.3.
export type T = {
	bool: () -> Codec<boolean>,
	int: (min: number?, max: number?) -> Codec<number>,
	number: (min: number, max: number, step: number) -> Codec<number>,
	f32: () -> Codec<number>,
	f64: () -> Codec<number>,
	angle: (step: number) -> Codec<number>,
	string: (maxBytes: number) -> Codec<string>,
	buffer: (maxBytes: number) -> Codec<buffer>,
	vector3: (min: number, max: number, step: number) -> Codec<Vector3>,
	vector3f32: () -> Codec<Vector3>,
	direction: (bits: number) -> Codec<Vector3>,
	rotation: (bits: number) -> Codec<CFrame>,
	cframe: (position: Codec<Vector3>, rotation: Codec<CFrame>) -> Codec<CFrame>,
	color3: () -> Codec<Color3>,
	enum: ((items: { string }) -> Codec<string>) & ((enum: Enum) -> Codec<unknown>),
	instance: (className: string?) -> Codec<Instance>,
	optional: <C>(codec: C) -> Codec<Infer<C>?>,
	array: <C>(codec: C, maxCount: number) -> Codec<{ Infer<C> }>,
	map: <K, V>(key: K, value: V, maxCount: number) -> Codec<{ [Infer<K>]: Infer<V> }>,
	union: <S>(variants: S) -> Codec<Tagged<S>>,
	custom: <V>(spec: CustomSpec<V>) -> Codec<V>,
	convert: <B, U>(
		base: B,
		decode: (value: Infer<B>) -> U,
		encode: (value: U) -> Infer<B>
	) -> Codec<U>,
}

--- A connection returned by `connect`.
export type Connection = {
	disconnect: (self: Connection) -> (),
}

--- Who a server send goes to.
export type Target = Player | { Player }

--- Why a request failed (v5.md §3.5).
export type Failure = "timeout" | "rejected" | "unanswered" | "left" | "shutdown"

--- A request's result; requests never throw.
export type Result<R> = { ok: true, value: R } | { ok: false, error: Failure }

--- A signal of a collection.
export type Signal<T...> = {
	connect: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
}

--- The server's side of an event the client sends.
export type ServerInbound<T> = {
	connect: (self: ServerInbound<T>, handler: (player: Player, value: T) -> ()) -> Connection,
	validate: (self: ServerInbound<T>, validator: (player: Player, value: T) -> boolean) -> (),
}

--- The client's side of an event the client sends.
export type ClientOutbound<T> = {
	fire: (self: ClientOutbound<T>, value: T) -> (),
}

--- The server's side of an event the server sends.
export type ServerOutbound<T> = {
	fire: (self: ServerOutbound<T>, target: Target, value: T) -> (),
}

--- The client's side of an event the server sends.
export type ClientInbound<T> = {
	connect: (self: ClientInbound<T>, handler: (value: T) -> ()) -> Connection,
}

--- The server's side of a request the client asks.
export type ServerResponder<T, R> = {
	handle: (self: ServerResponder<T, R>, handler: (player: Player, value: T) -> R) -> (),
	validate: (self: ServerResponder<T, R>, validator: (player: Player, value: T) -> boolean) -> (),
}

--- The client's side of a request the client asks.
export type ClientAsker<T, R> = {
	invoke: (self: ClientAsker<T, R>, value: T) -> Result<R>,
}

--- The server's side of a request the server asks.
export type ServerAsker<T, R> = {
	invoke: (self: ServerAsker<T, R>, player: Player, value: T) -> Result<R>,
}

--- The client's side of a request the server asks.
export type ClientResponder<T, R> = {
	handle: (self: ClientResponder<T, R>, handler: (value: T) -> R) -> (),
}

--- The server's side of a keyed collection.
export type ServerCollection<K, T> = {
	set: (self: ServerCollection<K, T>, key: K, record: T) -> (),
	patch: (self: ServerCollection<K, T>, key: K, patch: Partial<T>) -> (),
	remove: (self: ServerCollection<K, T>, key: K) -> (),
	audience: (self: ServerCollection<K, T>, key: K, target: Target) -> (),
}

--- The client's side of a keyed collection.
export type ClientCollection<K, T> = {
	get: (self: ClientCollection<K, T>, key: K) -> T?,
	added: Signal<K, T>,
	changed: Signal<K, T, T>,
	removed: Signal<K>,
}

--- The server's side of a singleton collection, which has no key.
export type ServerSingleton<T> = {
	set: (self: ServerSingleton<T>, record: T) -> (),
	patch: (self: ServerSingleton<T>, patch: Partial<T>) -> (),
	remove: (self: ServerSingleton<T>) -> (),
	audience: (self: ServerSingleton<T>, target: Target) -> (),
}

--- The client's side of a singleton collection.
export type ClientSingleton<T> = {
	get: (self: ClientSingleton<T>) -> T?,
	added: Signal<T>,
	changed: Signal<T, T>,
	removed: Signal<>,
}

--[=[
	The value type of a definition's option, nil when it is absent.

	@param  definition a definition's option table type
	@param  option     the option's name, as a string singleton
	@return the value type of its codec, or nil
]=]
export type function OptionValue(definition, option)
	local codec = definition:readproperty(option)
	if codec == nil then
		return types.singleton(nil)
	end

	return Infer(codec)
end

--[=[
	The `from` option of a definition.

	@param  definition a definition's option table type
	@return `"client"` or `"server"`, or a marker string when `from` is neither
]=]
export type function FromOf(definition)
	local from = definition:readproperty(types.singleton("from"))
	if from == nil or not from:is("singleton") then
		return types.singleton('[Lync] expected from = "client" or "server"')
	end

	return from
end

--[=[
	Whether a collection has a `key`.

	@param  definition a collection's option table type
	@return `"keyed"`, or `"singleton"` with no key
]=]
export type function KeyOf(definition)
	if definition:readproperty(types.singleton("key")) == nil then
		return types.singleton("singleton")
	end

	return types.singleton("keyed")
end

-- The definition types pick a side table with the built-in `index` rather than passing both to a
-- type function: a type function given side tables that hold error types (an unknown `Vector3`,
-- say) crashed luau-analyze at the first method call through a view.

--- An event, with the types of both its sides.
export type EventDef<D> = index<{
	client: {
		read _server: ServerInbound<OptionValue<D, "data">>,
		read _client: ClientOutbound<OptionValue<D, "data">>,
	},
	server: {
		read _server: ServerOutbound<OptionValue<D, "data">>,
		read _client: ClientInbound<OptionValue<D, "data">>,
	},
}, FromOf<D>>

--- A request, with the types of both its sides.
export type RequestDef<D> = index<{
	client: {
		read _server: ServerResponder<OptionValue<D, "data">, OptionValue<D, "reply">>,
		read _client: ClientAsker<OptionValue<D, "data">, OptionValue<D, "reply">>,
	},
	server: {
		read _server: ServerAsker<OptionValue<D, "data">, OptionValue<D, "reply">>,
		read _client: ClientResponder<OptionValue<D, "data">, OptionValue<D, "reply">>,
	},
}, FromOf<D>>

--- A collection, with the types of both its sides.
export type CollectionDef<D> = index<{
	keyed: {
		read _server: ServerCollection<OptionValue<D, "key">, OptionValue<D, "data">>,
		read _client: ClientCollection<OptionValue<D, "key">, OptionValue<D, "data">>,
	},
	singleton: {
		read _server: ServerSingleton<OptionValue<D, "data">>,
		read _client: ClientSingleton<OptionValue<D, "data">>,
	},
}, KeyOf<D>>

--- A planned schema; `_definitions` exists only in the type.
export type Schema<Defs> = {
	ir: Ir.Namespace,
	_definitions: Defs,
}

--[=[
	Selects one side's types from every definition of a schema.

	@param  schema a `Schema<Defs>`
	@param  side   `"_server"` or `"_client"`
	@return a table of each definition's side types by name, with a marker string for any value
	        that is not a definition
]=]
export type function SideOf(schema, side)
	local definitions = schema:readproperty(types.singleton("_definitions"))
	if definitions == nil or not definitions:is("table") then
		return types.singleton("[Lync] expected a schema from Lync.schema")
	end

	local view = types.newtable()
	for key, property in definitions:properties() do
		local definition = property.read
		local sideTypes = nil
		if definition ~= nil and definition:is("table") then
			sideTypes = definition:readproperty(side)
		end

		if sideTypes == nil then
			view:setproperty(key, types.singleton("[Lync] expected a definition from Lync.event"))
			continue
		end

		view:setproperty(key, sideTypes)
	end

	return view
end

--- The server's view of a schema (v5.md §3.5).
export type ServerView<S> = SideOf<S, "_server">

--- The client's view of a schema (v5.md §3.5).
export type ClientView<S> = SideOf<S, "_client">

--[=[
	`Lync.event`. The intersection keeps the literal `from` a singleton under the new solver
	(v5.md §3.1); its field is `read` so that the old solver, which drops `read` fields here, sees
	`D & {}` and accepts the literal it would otherwise widen to `string`.
]=]
export type Event = <D>(options: D & { read from: "client" | "server" }) -> EventDef<D>

--- `Lync.request`, with `from` as in `Event`.
export type Request = <D>(options: D & { read from: "client" | "server" }) -> RequestDef<D>

--- `Lync.collection`.
export type Collection = <D>(options: D) -> CollectionDef<D>

return table.freeze(Types)
