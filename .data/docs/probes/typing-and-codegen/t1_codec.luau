--!strict
-- T1 probe: plain-table codecs { read _value: T, ...non-generic methods } + Infer<S>

export type Codec<T> = {
	read _value: T,
	size: number,
	write: (b: buffer, o: number, v: T) -> number,
	read: (b: buffer, o: number) -> (T, number),
}

local function make(size: number): any
	return { size = size } :: any
end

local u8: Codec<number> = make(1)
local f32: Codec<number> = make(4)
local bool: Codec<boolean> = make(1)
local str: Codec<string> = make(-1)

local function array<T>(c: Codec<T>): Codec<{ T }>
	return make(-1)
end
local function optional<T>(c: Codec<T>): Codec<T?>
	return make(-1)
end
local function map<K, V>(k: Codec<K>, v: Codec<V>): Codec<{ [K]: V }>
	return make(-1)
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
	error(`Infer: not a codec or table of codecs: {s.tag}`)
end

local function struct<S>(s: S): Codec<Infer<S>>
	return make(-1)
end

-- nested raw table of codecs (no struct wrapper)
local Schema = {
	id = u8,
	pos = { x = f32, y = f32 },
	alive = bool,
	nick = optional(str),
	tags = array(str),
	scores = map(str, u8),
	inner = struct({ a = u8, b = optional(bool) }),
}

type Rec = Infer<typeof(Schema)>

local rv: Rec = nil :: any
local _reveal: "REVEAL_T1" = rv -- error prints the full inferred type

-- success: exact literal accepted (nick omitted -> optional)
local ok: Rec = {
	id = 1,
	pos = { x = 1, y = 2 },
	alive = true,
	tags = { "a" },
	scores = { k = 3 },
	inner = { a = 1 },
}

-- failures, each must be rejected
local bad1: Rec = { id = "x", pos = { x = 1, y = 2 }, alive = true, tags = {}, scores = {}, inner = { a = 1 } } -- wrong type
local bad2: Rec = { pos = { x = 1, y = 2 }, alive = true, tags = {}, scores = {}, inner = { a = 1 } } -- missing id
local bad3: Rec = { id = 1, pos = { x = 1 }, alive = true, tags = {}, scores = {}, inner = { a = 1 } } -- missing nested y
local bad4: Rec = { id = 1, pos = { x = 1, y = 2 }, alive = true, tags = { 1 }, scores = {}, inner = { a = 1 } } -- array elem type
local bad5: Rec = { id = 1, pos = { x = 1, y = 2 }, alive = true, tags = {}, scores = { k = "v" }, inner = { a = 1 } } -- map value type
local bad6: Rec = { id = 1, pos = { x = 1, y = 2 }, alive = true, tags = {}, scores = {}, inner = { a = 1, b = 5 } } -- optional wrong type
local bad7: Rec = { id = 1, pos = { x = 1, y = 2 }, alive = true, tags = {}, scores = {}, inner = { a = 1 }, extra = 1 } -- extra key
-- field reads
local n: number = rv.id
local s: string = rv.nick -- must fail: string? into string
local y: string = rv.pos.y -- must fail
-- struct() codec value type
local sc = struct(Schema)
local _reveal2: "REVEAL_T1_STRUCT" = sc._value
return nil
