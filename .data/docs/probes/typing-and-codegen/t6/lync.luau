--!strict
-- T6 library stand-in: one shared schema, side views
export type Player = { Name: string, UserId: number }
export type Codec<T> = { read _value: T, size: number }
local function make(size: number): any
	return { size = size }
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

-- Plain generic side types
export type ServerPacket<T> = {
	fire: (self: ServerPacket<T>, player: Player, value: T) -> (),
	fireAll: (self: ServerPacket<T>, value: T) -> (),
	connect: (self: ServerPacket<T>, f: (value: T, player: Player) -> ()) -> (),
}
export type ClientPacket<T> = {
	fire: (self: ClientPacket<T>, value: T) -> (),
	connect: (self: ClientPacket<T>, f: (value: T) -> ()) -> (),
}
-- A definition carries both side types as phantoms; the view type function only selects one.
export type Packet<T> = {
	read _value: T,
	read _server: ServerPacket<T>,
	read _client: ClientPacket<T>,
}

type function Payload(s)
	return Infer(s)
end

-- Approach G (generic types selected by a type function)
type function SelectSide(schema, side)
	local out = types.newtable()
	for key, prop in schema:properties() do
		local view = prop.read:readproperty(side)
		if not view then
			error(`'{key:value()}' is not a packet definition`)
		end
		out:setproperty(key, view)
	end
	return out
end

-- Approach F (side types built entirely in a type function)
type function BuildSide(schema, side, player)
	local out = types.newtable()
	for key, prop in schema:properties() do
		local payload = prop.read:readproperty(types.singleton("_value"))
		local t = types.newtable()
		if side:value() == "server" then
			t:setproperty(types.singleton("fire"), types.newfunction({ head = { types.unknown, player, payload } }, { head = {} }))
			t:setproperty(types.singleton("fireAll"), types.newfunction({ head = { types.unknown, payload } }, { head = {} }))
			local h = types.newfunction({ head = { payload, player } }, { head = {} })
			t:setproperty(types.singleton("connect"), types.newfunction({ head = { types.unknown, h } }, { head = {} }))
		else
			t:setproperty(types.singleton("fire"), types.newfunction({ head = { types.unknown, payload } }, { head = {} }))
			local h = types.newfunction({ head = { payload } }, { head = {} })
			t:setproperty(types.singleton("connect"), types.newfunction({ head = { types.unknown, h } }, { head = {} }))
		end
		out:setproperty(key, t)
	end
	return out
end

local Lync = {}
Lync.u8 = make(1) :: Codec<number>
Lync.str = make(-1) :: Codec<string>
function Lync.packet<S>(s: S): Packet<Payload<S>>
	return make(0)
end
function Lync.serverG<S>(schema: S): SelectSide<S, "_server">
	return schema :: any
end
function Lync.clientG<S>(schema: S): SelectSide<S, "_client">
	return schema :: any
end
function Lync.serverF<S>(schema: S): BuildSide<S, "server", Player>
	return schema :: any
end
function Lync.clientF<S>(schema: S): BuildSide<S, "client", Player>
	return schema :: any
end
return Lync
