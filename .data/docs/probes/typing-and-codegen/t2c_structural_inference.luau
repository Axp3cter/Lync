--!strict
-- T2 probe: tagged-union constructor -> discriminated union that narrows on v.kind
export type Codec<T> = {
	read _value: T,
	size: number,
	write: (self: Codec<T>, b: buffer, o: number, v: T) -> number,
}
local function make(size: number): any
	return { size = size }
end
local u8: Codec<number> = make(1)
local str: Codec<string> = make(-1)
local vec: Codec<vector> = make(12)

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
	error(`Infer: not a codec or table of codecs: {s.tag}`)
end

-- variants: { [name]: table-of-codecs }  ->  union of { kind: "name", ...fields }
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

local function tagged<S>(variants: S): Codec<Tagged<S>>
	return make(-1)
end

local Shot = tagged({
	hit = { target = u8, at = vec },
	miss = { reason = str },
	none = {},
})
type Packet<T> = {
	connect: (self: Packet<T>, f: (T) -> ()) -> (),
	fire: (self: Packet<T>, v: T) -> (),
}
local function packet<T>(c: Codec<T>): Packet<T>
	return make(0)
end
local P = packet(Shot)
local _r1: "R1" = P
local _r2: "R2" = Shot
local P2 = packet(u8)
local _r3: "R3" = P2
P2:connect(function(v) local _r4: "R4" = v end)
local P3: Packet<typeof(Shot._value)> = packet(Shot)
P3:connect(function(v) local _r5: "R5" = v end)
return nil
