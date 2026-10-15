--!strict

--[=[
	ApiTypes

	Types-only prototype of the Lync v5 public surface, used to verify that every construct in
	`docs/v5-api.md` types the way the document says. Each expected type error is marked `-- error:`.

	Checked with `luau.py check --roblox` (luau-lsp 1.70.1, Luau 0.740, new solver).
]=]


-- Types -------------------------------------------------------------------------------------------

export type Codec<T> = {
	read _value:    T,
	read optional:  (self: Codec<T>) -> Optional<T>,
	read latest:    (self: Codec<T>, rate: number?) -> Latest<T>,
	read partition: (self: Codec<T>) -> Partition<T>,
}

export type Optional<T> = {
	read _value:   T?,
	read latest:   (self: Optional<T>, rate: number?) -> Latest<T?>,
}

export type Latest<T> = {
	read _value:  T,
	read _latest: true,
}

export type Partition<T> = {
	read _value:     T,
	read _partition: true,
}


type function InferSchema(schema)
	local function infer(node: type): type
		if node:is("intersection") then
			for _, part in node:components() do
				if part:is("table") then
					local carried = part:readproperty(types.singleton("_value"))
					if carried ~= nil then
						return carried
					end
				end
			end
			error("a callable value in a schema must be a codec")
		end

		if not node:is("table") then
			error("a schema is a codec or a table of codecs")
		end

		local carried = node:readproperty(types.singleton("_value"))
		if carried ~= nil then
			return carried
		end

		local record = types.newtable()
		for name, property in node:properties() do
			local field = property.read or property.write
			if field == nil then
				error("a schema field has no type")
			end
			record:setproperty(name, infer(field))
		end

		return record
	end

	return infer(schema)
end


type function MessageSchema(schema)
	local function inspect(node: type)
		if not node:is("table") then
			return
		end

		if node:readproperty(types.singleton("_latest")) ~= nil then
			error("latest marks a collection field; events and requests cannot use it")
		end

		if node:readproperty(types.singleton("_partition")) ~= nil then
			error("partition marks a collection field; events and requests cannot use it")
		end

		if node:readproperty(types.singleton("_value")) == nil then
			for _, property in node:properties() do
				local field = property.read or property.write
				if field ~= nil then
					inspect(field)
				end
			end
		end
	end

	inspect(schema)

	return InferSchema(schema)
end


type function UnionSchema(variants)
	local members = {}
	for name, property in variants:properties() do
		local variant = property.read or property.write
		if variant == nil then
			error("a union variant has no type")
		end

		local record = InferSchema(variant)
		record:setproperty(types.singleton("kind"), name)
		table.insert(members, record)
	end

	return types.unionof(table.unpack(members))
end


type function FlagsSchema(names)
	local record = types.newtable()
	for name in names:properties() do
		record:setproperty(name, types.boolean)
	end

	return record
end


type function PartitionOf(schema)
	for _, property in schema:properties() do
		local field = property.read or property.write
		if field ~= nil and field:is("table") then
			if field:readproperty(types.singleton("_partition")) ~= nil then
				local carried = field:readproperty(types.singleton("_value"))
				if carried ~= nil then
					return carried
				end
			end
		end
	end

	return types.never
end


type function ViewOf(namespace, side)
	local key  = `_{side:value()}`
	local view = types.newtable()
	for name, property in namespace:properties() do
		local definition = property.read or property.write
		if definition == nil then
			error("a namespace entry has no type")
		end

		local sideView = definition:readproperty(types.singleton(key))
		if sideView == nil then
			error("a namespace entry must be an event, a request or a collection")
		end
		view:setreadproperty(name, sideView)
	end

	return view
end


export type Infer<S> = InferSchema<S>

export type Result<T> =
	| { ok: true, value: T }
	| { ok: false, reason: "Timeout" | "Unanswered" | "Left" | "Shutdown" }

export type Recipients = Player | { Player }

export type Connection = {
	read disconnect: (self: Connection) -> (),
}

export type Signal<A...> = {
	read connect: (self: Signal<A...>, listener: (A...) -> ()) -> Connection,
}


export type ServerEvent<T> = {
	read validate: (self: ServerEvent<T>, check: (value: T, player: Player) -> string?) -> (),
	read limit:    (self: ServerEvent<T>, perSecond: number) -> (),
	read fire:    (self: ServerEvent<T>, recipients: Recipients, value: T) -> (),
	read connect: (self: ServerEvent<T>, listener: (value: T, player: Player) -> ()) -> Connection,
}

export type ClientEvent<T> = {
	read fire:    (self: ClientEvent<T>, value: T) -> (),
	read connect: (self: ClientEvent<T>, listener: (value: T) -> ()) -> Connection,
}

export type TimedServerEvent<T> = {
	read validate: (self: TimedServerEvent<T>, check: (value: T, player: Player) -> string?) -> (),
	read limit:    (self: TimedServerEvent<T>, perSecond: number) -> (),
	read fire:    (self: TimedServerEvent<T>, recipients: Recipients, value: T) -> (),
	read connect: (self: TimedServerEvent<T>, listener: (value: T, player: Player, sentAt: number) -> ()) -> Connection,
}

export type TimedClientEvent<T> = {
	read fire:    (self: TimedClientEvent<T>, value: T) -> (),
	read connect: (self: TimedClientEvent<T>, listener: (value: T, sentAt: number) -> ()) -> Connection,
}

export type Event<T> = {
	read _server:     ServerEvent<T>,
	read _client:     ClientEvent<T>,
	read unreliable:  (self: Event<T>) -> LossyEvent<T>,
	read latest:      (self: Event<T>, rate: number?) -> LossyEvent<T>,
	read timestamped: (self: Event<T>) -> TimedEvent<T>,
}

export type TimedEvent<T> = {
	read _server:    TimedServerEvent<T>,
	read _client:    TimedClientEvent<T>,
	read unreliable: (self: TimedEvent<T>) -> TimedLossyEvent<T>,
	read latest:     (self: TimedEvent<T>, rate: number?) -> TimedLossyEvent<T>,
}

export type LossyEvent<T> = {
	read _server:     ServerEvent<T>,
	read _client:     ClientEvent<T>,
	read timestamped: (self: LossyEvent<T>) -> TimedLossyEvent<T>,
}

export type TimedLossyEvent<T> = {
	read _server: TimedServerEvent<T>,
	read _client: TimedClientEvent<T>,
}


export type ServerRequest<Q, R> = {
	read validate: (self: ServerRequest<Q, R>, check: (value: Q, player: Player) -> string?) -> (),
	read limit:    (self: ServerRequest<Q, R>, perSecond: number) -> (),
	read invoke: (self: ServerRequest<Q, R>, player: Player, value: Q) -> Result<R>,
	read handle: (self: ServerRequest<Q, R>, handler: (value: Q, player: Player) -> R) -> (),
}

export type ClientRequest<Q, R> = {
	read invoke: (self: ClientRequest<Q, R>, value: Q) -> Result<R>,
	read handle: (self: ClientRequest<Q, R>, handler: (value: Q) -> R) -> (),
}

export type Request<Q, R> = {
	read _server: ServerRequest<Q, R>,
	read _client: ClientRequest<Q, R>,
	read timeout: (self: Request<Q, R>, seconds: number) -> Request<Q, R>,
}


export type ServerCollection<R, K> = {
	[number]:     R?,
	read update:  (self: ServerCollection<R, K>, id: number, patch: { [string]: unknown }) -> (),
	read clear:   (self: ServerCollection<R, K>) -> (),
	read show:    (self: ServerCollection<R, K>, key: K, recipients: Recipients) -> (),
	read hide:    (self: ServerCollection<R, K>, key: K) -> (),
	read added:   Signal<number, R>,
	read changed: Signal<number, R, R>,
	read removed: Signal<number, R>,
}

export type ClientCollection<R> = {
	read [number]: R?,
	read added:    Signal<number, R>,
	read changed:  Signal<number, R, R>,
	read removed:  Signal<number, R>,
}

export type Collection<R, K> = {
	read _server: ServerCollection<R, K>,
	read _client: ClientCollection<R>,
}


type Instances = Codec<Instance?> & {
	read Part:   Codec<Part?>,
	read Player: Codec<Player?>,
	read Model:  Codec<Model?>,
}

type Enums = {
	read Material: Codec<Enum.Material>,
	read KeyCode:  Codec<Enum.KeyCode>,
}


-- Module ------------------------------------------------------------------------------------------

local Lync = ({} :: any) :: {
	boolean:   Codec<boolean>,
	integer:   Codec<number> & ((min: number, max: number) -> Codec<number>),
	number:    Codec<number> & ((min: number, max: number, step: number) -> Codec<number>),
	string:    Codec<string> & ((maxBytes: number) -> Codec<string>),
	vector3:   Codec<Vector3> & ((min: number, max: number, step: number) -> Codec<Vector3>),
	direction: Codec<Vector3> & ((step: number) -> Codec<Vector3>),
	color3:    Codec<Color3> & ((step: number) -> Codec<Color3>),
	instance:  Instances,
	enum:      Enums,

	array:   <S>(element: S, maxCount: number?) -> Codec<{ InferSchema<S> }>,
	map:     <K, V>(key: K, value: V, maxCount: number?) -> Codec<{ [InferSchema<K>]: InferSchema<V> }>,
	oneOf:   <T>(names: T) -> Codec<keyof<T>>,
	flags:   <T>(names: T) -> Codec<FlagsSchema<T>>,
	union:   <V>(variants: V) -> Codec<UnionSchema<V>>,
	convert: <S, U>(wire: S, conversion: {
		decode: (value: InferSchema<S>) -> U,
		encode: (value: U) -> InferSchema<S>,
	}) -> Codec<U>,

	event:      <S>(schema: S) -> Event<MessageSchema<S>>,
	request:    <Q, R>(request: Q, reply: R) -> Request<MessageSchema<Q>, MessageSchema<R>>,
	collection: <S>(schema: S) -> Collection<InferSchema<S>, PartitionOf<S>>,
	namespace:  <D>(definitions: D) -> D,

	server: <D>(namespace: D) -> ViewOf<D, "server">,
	client: <D>(namespace: D) -> ViewOf<D, "client">,
	all:    Recipients,
}


-- Main --------------------------------------------------------------------------------------------

local Shared = Lync.namespace({
	chat = Lync.event(Lync.string(200)),

	strike = Lync.event({
		target   = Lync.integer(0, 255),
		position = Lync.vector3(-512, 512, 0.1),
		weapon   = Lync.instance.Model,
	}):unreliable():timestamped(),

	outcome = Lync.event(Lync.union({
		hit  = { target = Lync.integer(0, 255) },
		miss = { distance = Lync.number(0, 100, 0.1) },
	})),

	controls = Lync.event({
		pressed = Lync.flags({ jump = true, crouch = true }),
		aim     = Lync.direction(1),
		size    = Lync.convert({ scale = Lync.number, offset = Lync.integer(-4096, 4096) }, {
			decode = function(wire): UDim
				return UDim.new(wire.scale, wire.offset)
			end,
			encode = function(size: UDim)
				return { scale = size.Scale, offset = size.Offset }
			end,
		}),
	}),

	sell = Lync.request(Lync.oneOf({ sword = true, shield = true }), Lync.integer(0, 100_000)),

	fighters = Lync.collection({
		team      = Lync.oneOf({ red = true, blue = true }):partition(),
		health    = Lync.integer(0, 100),
		position  = Lync.vector3(-512, 512, 0.1):latest(20),
		title     = Lync.string(16):optional(),
		tint      = Lync.color3(1 / 31),
		material  = Lync.enum.Material,
		inventory = Lync.array(Lync.string(16), 32),
		stats     = Lync.map(Lync.string(16), Lync.integer),
	}),
})


-- Server view

local Server = Lync.server(Shared)

Server.chat:limit(5)
Server.chat:validate(function(text, player)
	return if #text > 0 then nil else "chat text must not be empty"
end)

Server.chat:connect(function(text, player)
	Server.chat:fire(Lync.all, `{player.Name}: {text}`)
end)
Server.chat:fire(Lync.all, 5) -- error: number is not a string

Server.strike:connect(function(strike, player, sentAt)
	local _when: number = sentAt
	local _target: number = strike.target
end)

Server.sell:handle(function(item, player)
	local _length: number = #item
	return 100
end)
Server.sell:handle(function(item, player)
	return "free" -- error: the reply must be a number
end)

Server.fighters[1] = {
	team      = "red",
	health    = 100,
	position  = Vector3.zero,
	title     = nil,
	tint      = Color3.new(1, 0, 0),
	material  = Enum.Material.Grass,
	inventory = { "sword" },
	stats     = { speed = 5 },
}
Server.fighters[2] = nil
Server.fighters:show("red", Lync.all)
Server.fighters:show("green", Lync.all) -- error: not a partition key

Server.fighters.removed:connect(function(id, previous)
	local _team: "red" | "blue" = previous.team
end)


-- Client view

local Client = Lync.client(Shared)

Client.chat:fire("hello")
Client.chat:fire(Lync.all, "hello") -- error: a client fires at the server only

Client.outcome:connect(function(outcome)
	if outcome.kind == "hit" then
		local _target: number = outcome.target
	elseif outcome.kind == "miss" then
		local _distance: number = outcome.distance
	end
end)

Client.controls:fire({ pressed = { jump = true, crouch = false }, aim = Vector3.yAxis, size = UDim.new(0, 5) })
Client.controls:fire({ pressed = { jump = true, sprint = true }, aim = Vector3.yAxis, size = UDim.new(0, 5) }) -- error: no sprint flag

local sold = Client.sell:invoke("sword")
if sold.ok then
	local _price: number = sold.value
end
Client.sell:invoke("axe") -- error: not one of the declared names

Client.fighters[1] = nil -- error: a client cannot write a collection

for id, fighter in Client.fighters do
	local _id: number = id
	local _health: number = fighter.health
end
local _count: number = #Client.fighters


-- Declarations that must fail

local _ = Lync.enum.Materail -- error: no such Enum

local _misused = Lync.event({ position = Lync.vector3:latest(20) }) -- error: latest is for collection fields

local Lossy = Lync.event(Lync.string):unreliable()
Lossy:latest(10) -- error: an unreliable event cannot also be latest

Client.chat:limit(5) -- error: policy exists only on the server view
