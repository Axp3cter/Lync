--!optimize 2
-- The same shard with its per-build values read from a table at run time instead of compiled in:
-- what a runtime-only path would do to get the same rotation.
local Build = { C = { 0x736f6d65, 0x646f7261, 0x6c796765, 0x74656462 }, order = { "target", "damage", "crit" },
	id = { hit = 1, shoot = 2, reload = 3 } }
local C = Build.C

local function tagWord(k0: number, k1: number, m: number): number
	local v0 = bit32.bxor(k0, C[1])
	local v1 = bit32.bxor(k1, C[2])
	local v2 = bit32.bxor(k0, C[3])
	local v3 = bit32.bxor(bit32.bxor(k1, C[4]), m)
	v0 = bit32.band(v0 + v1, 0xFFFFFFFF)
	v1 = bit32.bxor(bit32.lrotate(v1, 5), v0)
	v0 = bit32.lrotate(v0, 16)
	v2 = bit32.band(v2 + v3, 0xFFFFFFFF)
	v3 = bit32.bxor(bit32.lrotate(v3, 8), v2)
	return bit32.bxor(bit32.bxor(v0, v1), bit32.bxor(v2, v3))
end

local writers = {
	target = function(b: buffer, o: number, v: any): number buffer.writeu16(b, o, v.target); return o + 2 end,
	damage = function(b: buffer, o: number, v: any): number buffer.writeu16(b, o, v.damage); return o + 2 end,
	crit = function(b: buffer, o: number, v: any): number buffer.writeu8(b, o, if v.crit then 1 else 0); return o + 1 end,
}
local function writeHit(b: buffer, o: number, v: any): number
	for _, field in Build.order do
		o = writers[field](b, o, v)
	end
	return o
end

local handlers = {
	[Build.id.hit] = function(b: buffer, o: number): number return buffer.readu16(b, o) end,
	[Build.id.shoot] = function(b: buffer, o: number): number return buffer.readu8(b, o) end,
	[Build.id.reload] = function(): number return 0 end,
}
local function dispatch(id: number, b: buffer, o: number): number
	local h = handlers[id]
	return if h then h(b, o) else -1
end

return { tagWord = tagWord, writeHit = writeHit, dispatch = dispatch }
