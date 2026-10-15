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

local function onShot(v: typeof(Shot._value))
	local _reveal: "REVEAL_T2" = v
	if v.kind == "hit" then
		local t: number = v.target -- ok
		local r: string = v.reason -- must fail: not in hit
	elseif v.kind == "miss" then
		local r: string = v.reason -- ok
		local t: number = v.target -- must fail
	else
		local _reveal_else: "REVEAL_T2_ELSE" = v
	end
	if v.kind == "hti" then -- misspelled discriminant: is it reported?
	end
end

-- construction of variants
local okv: typeof(Shot._value) = { kind = "hit", target = 1, at = vector.create(0, 0, 0) }
local badv1: typeof(Shot._value) = { kind = "hit", reason = "x" } -- must fail (wrong fields for tag)
local badv2: typeof(Shot._value) = { kind = "hti", target = 1, at = vector.create(0, 0, 0) } -- must fail (bad tag)

-- handler passed as an argument to a function taking Codec<T>
local function on<T>(c: Codec<T>, f: (T) -> ())
end
on(Shot, function(v)
	if v.kind == "miss" then
		local r: string = v.reason -- ok
		local t: number = v.target -- must fail
	end
end)
return nil
