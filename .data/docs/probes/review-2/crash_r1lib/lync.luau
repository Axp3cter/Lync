--!strict
-- review-2 crash_r1lib: unchanged copy of review-1/pipe/lync.luau, to show the analyzer crash predates draft 2
-- review-1 pipeline stand-in for the v5 draft-1 API (§3.3-§3.6): option-table definitions,
-- codec markers, side views from `from`, results, collections with a literal-generic patch.
export type Player = { Name: string, UserId: number }

-- Codec with the §3.6 markers as non-generic self methods that return the same codec type.
export type Codec<T> = {
	read _value: T,
	newest: (self: Codec<T>) -> Codec<T>,
	priority: (self: Codec<T>, weight: number) -> Codec<T>,
	rate: (self: Codec<T>, hz: number) -> Codec<T>,
	owner: (self: Codec<T>) -> Codec<T>,
}
local function make(): any
	return {}
end

type function Infer(s)
	if s:is("table") then
		local v = s:readproperty(types.singleton("_value"))
		if v then
			return v
		end
		local out = types.newtable()
		for key, prop in s:properties() do
			out:setproperty(key, Infer(prop.read))
		end
		return out
	end
	error(`Infer: expected a codec or a table of codecs, got {s.tag}`)
end
export type function Payload(d)
	local data = d:readproperty(types.singleton("data"))
	if data == nil then
		return types.singleton(nil)
	end
	return Infer(data)
end
export type function Reply(d)
	return Infer(d:readproperty(types.singleton("reply")))
end
export type function Key(d)
	return Infer(d:readproperty(types.singleton("key")))
end
type function Tagged(variants)
	local members = {}
	for key, prop in variants:properties() do
		local rec = Infer(prop.read)
		local t = types.newtable()
		t:setproperty(types.singleton("kind"), key)
		for k, p in rec:properties() do
			t:setproperty(k, p.read)
		end
		table.insert(members, t)
	end
	return types.unionof(table.unpack(members))
end
type function Partial(t)
	local out = types.newtable()
	for key, prop in t:properties() do
		out:setproperty(key, types.optional(prop.read))
	end
	return out
end
type function StrictPatch(p, t)
	if not p:is("table") then
		error(`patch must be a table, got {p.tag}`)
	end
	for key, prop in p:properties() do
		local target = t:readproperty(key)
		if not target then
			error(`unknown field '{key:value()}' in patch`)
		end
		if not prop.read:issubtypeof(target) then
			error(`field '{key:value()}' has the wrong type`)
		end
	end
	return p
end

-- Side types (plain generic aliases, as T5-B and T6-G recommend)
export type Target = Player | { Player }
export type ServerInbound<T> = {
	connect: (self: ServerInbound<T>, f: (player: Player, value: T) -> ()) -> (),
	validate: (self: ServerInbound<T>, f: (player: Player, value: T) -> string?) -> (),
}
export type ClientOutbound<T> = { fire: (self: ClientOutbound<T>, value: T) -> () }
export type ServerOutbound<T> = { fire: (self: ServerOutbound<T>, target: Target, value: T) -> () }
export type ClientInbound<T> = { connect: (self: ClientInbound<T>, f: (value: T) -> ()) -> () }
export type Failure = "timeout" | "rejected" | "unanswered" | "left" | "shutdown"
export type Result<R> = { ok: true, value: R } | { ok: false, error: Failure }
export type ServerResponder<T, R> = { handle: (self: ServerResponder<T, R>, f: (player: Player, value: T) -> R) -> () }
export type ClientAsker<T, R> = { invoke: (self: ClientAsker<T, R>, value: T) -> Result<R> }
export type ServerCollection<K, T> = {
	set: (self: ServerCollection<K, T>, id: K, value: T) -> (),
	-- a literal-generic patch (T4b) breaks SelectSide (see ../r3_patch_in_view.luau); non-generic here
	patch: (self: ServerCollection<K, T>, id: K, p: Partial<T>) -> (),
	remove: (self: ServerCollection<K, T>, id: K) -> (),
}
export type ClientCollection<K, T> = { get: (self: ClientCollection<K, T>, id: K) -> T? }

-- Pick the side types from the `from` singleton
type function Sides(d, clientFrom, serverFrom)
	local from = d:readproperty(types.singleton("from"))
	if from == nil or not from:is("singleton") then
		error(`from must be "client" or "server", got {if from then from.tag else "nothing"}`)
	end
	local pick = if from:value() == "client" then clientFrom else serverFrom
	return pick
end
export type EventDef<D> = Sides<
	D,
	{ read _server: ServerInbound<Payload<D>>, read _client: ClientOutbound<Payload<D>> },
	{ read _server: ServerOutbound<Payload<D>>, read _client: ClientInbound<Payload<D>> }
>
export type RequestDef<D> = {
	read _server: ServerResponder<Payload<D>, Reply<D>>,
	read _client: ClientAsker<Payload<D>, Reply<D>>,
}
export type CollectionDef<D> = {
	read _server: ServerCollection<Key<D>, Payload<D>>,
	read _client: ClientCollection<Key<D>, Payload<D>>,
}
type function SelectSide(schema, side)
	local out = types.newtable()
	for key, prop in schema:properties() do
		local view = prop.read:readproperty(side)
		if not view then
			error(`'{key:value()}' is not a definition`)
		end
		out:setproperty(key, view)
	end
	return out
end

local Lync = {}
local t = {}
function t.int(min: number?, max: number?): Codec<number>
	return make()
end
function t.string(maxBytes: number): Codec<string>
	return make()
end
function t.vector3(min: number?, max: number?, step: number?): Codec<vector>
	return make()
end
function t.optional<T>(c: Codec<T>): Codec<T?>
	return make()
end
function t.array<T>(c: Codec<T>, maxCount: number): Codec<{ T }>
	return make()
end
function t.union<S>(variants: S): Codec<Tagged<S>>
	return make()
end
-- list-form enum and flags, as draft 1 writes them
function t.enum<T>(names: { T }): Codec<T>
	return make()
end
Lync.types = t

-- naive signature: `from` widens
function Lync.eventNaive<D>(def: D): EventDef<D>
	return make()
end
-- signature with an expected type for the option fields
type EventOptions = {
	from: "client" | "server",
	lane: ("reliable" | "unreliable")?,
	timestamped: boolean?,
	rate: number?,
}
function Lync.event<D>(def: D & { from: "client" | "server" }): EventDef<D>
	return make()
end
function Lync.request<D>(def: D & { from: "client" | "server" }): RequestDef<D>
	return make()
end
function Lync.collection<D>(def: D): CollectionDef<D>
	return make()
end
function Lync.schema<S>(name: string, defs: S): S
	return defs
end
function Lync.server<S>(schema: S): SelectSide<S, "_server">
	return make()
end
function Lync.client<S>(schema: S): SelectSide<S, "_client">
	return make()
end
return Lync
