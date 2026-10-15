--!nocheck
--!nolint UnknownGlobal
-- T5 library stand-in: codecs + three ways to type a packet definition
export type Player = { Name: string, UserId: number } -- stand-in for Roblox Player (plain luau-analyze)

export type Codec<T> = {
	read _value: T,
	size: number,
	write: (self: Codec<T>, b: buffer, o: number, v: T) -> number,
}
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
export type function Payload(s)
	return Infer(s)
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

-- Approach A: whole definition type computed by a type function
type function PacketTF(s, player)
	local payload = Infer(s)
	local t = types.newtable()
	local selfT = types.unknown
	local handler = types.newfunction({ head = { payload, player } }, { head = {} })
	t:setproperty(types.singleton("connect"), types.newfunction({ head = { selfT, handler } }, { head = {} }))
	t:setproperty(types.singleton("fire"), types.newfunction({ head = { selfT, payload } }, { head = {} }))
	return t
end

-- Approach B: plain generic table type; type function computes only the payload
export type Packet<T> = {
	connect: (self: Packet<T>, f: (value: T, player: Player) -> ()) -> (),
	fire: (self: Packet<T>, value: T) -> (),
}

local Lync = {}
Lync.u8 = make(1) :: Codec<number>
Lync.f32 = make(4) :: Codec<number>
Lync.bool = make(1) :: Codec<boolean>
Lync.str = make(-1) :: Codec<string>
Lync.vec = make(12) :: Codec<vector>
function Lync.optional<T>(c: Codec<T>): Codec<T?>
	return make(-1)
end
function Lync.array<T>(c: Codec<T>): Codec<{ T }>
	return make(-1)
end
function Lync.struct<S>(s: S): Codec<Infer<S>>
	return make(-1)
end
function Lync.tagged<S>(s: S): Codec<Tagged<S>>
	return make(-1)
end

-- A: definition type computed wholesale
function Lync.packetA<S>(s: S): PacketTF<S, Player>
	return make(0)
end
-- B: Packet<Payload<S>>  (S is the raw argument type; no structural matching)
function Lync.packetB<S>(s: S): Packet<Payload<S>>
	return make(0)
end
-- C: structural inference of T from Codec<T>
function Lync.packetC<T>(c: Codec<T>): Packet<T>
	return make(0)
end
return Lync
