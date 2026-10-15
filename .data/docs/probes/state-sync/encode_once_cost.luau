--!native
--!strict
-- Encode-once vs per-viewer encoding for one record type (position + yaw + hp, 8 bytes quantized).
-- (a) quantize + write the record once (shared chunk)
-- (b) copy a shared 8-byte chunk into a viewer frame (buffer.copy)
-- (c) per-viewer delta against that viewer's own acked baseline: read baseline values, subtract,
--     zigzag + 1-or-2-byte varint per component (what per-client baselines force you to do)
local N = 200000
local src = buffer.create(N * 8)
local dst = buffer.create(N * 8 + 64)
local base = buffer.create(N * 8)
local xs, ys, zs = table.create(N, 0), table.create(N, 0), table.create(N, 0)
local seed = 9
local function rand(): number
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed / 2147483648
end
for i = 1, N do
	xs[i] = rand() * 2048 - 1024
	ys[i] = rand() * 256
	zs[i] = rand() * 2048 - 1024
	buffer.writeu16(base, (i - 1) * 8, math.floor((xs[i] + 1024) * 32) % 65536)
end

local function encodeOnce(): number
	local t = os.clock()
	for i = 1, N do
		local o = (i - 1) * 8
		buffer.writeu16(src, o, math.clamp(math.floor((xs[i] + 1024) * 32 + 0.5), 0, 65535))
		buffer.writeu16(src, o + 2, math.clamp(math.floor(ys[i] * 256 + 0.5), 0, 65535))
		buffer.writeu16(src, o + 4, math.clamp(math.floor((zs[i] + 1024) * 32 + 0.5), 0, 65535))
		buffer.writeu8(src, o + 6, 17)
		buffer.writeu8(src, o + 7, 100)
	end
	return (os.clock() - t) / N * 1e9
end

local function copyChunks(): number
	local t = os.clock()
	local at = 0
	for i = 1, N do
		buffer.copy(dst, at, src, (i - 1) * 8, 8)
		at += 8
	end
	return (os.clock() - t) / N * 1e9
end

local function perViewerDelta(): number
	local t = os.clock()
	local at = 0
	for i = 1, N do
		local o = (i - 1) * 8
		for c = 0, 2 do
			local v = buffer.readu16(src, o + c * 2) - buffer.readu16(base, o + c * 2)
			local z = if v >= 0 then v * 2 else -v * 2 - 1
			if z < 128 then
				buffer.writeu8(dst, at, z)
				at += 1
			else
				buffer.writeu8(dst, at, bit32.bor(z % 128, 128))
				buffer.writeu8(dst, at + 1, z // 128 % 256)
				at += 2
			end
		end
		buffer.writeu8(dst, at, buffer.readu8(src, o + 6))
		buffer.writeu8(dst, at + 1, buffer.readu8(src, o + 7))
		at += 2
	end
	return (os.clock() - t) / N * 1e9
end

local function median(f: () -> number): number
	local r = {}
	for k = 1, 7 do
		r[k] = f()
	end
	table.sort(r)
	return r[4]
end
print(`ns per record (median of 7 x {N})`)
print(`encode once (quantize + write 8 B): {string.format("%.1f", median(encodeOnce))}`)
print(`copy shared 8 B chunk (buffer.copy): {string.format("%.1f", median(copyChunks))}`)
print(`per-viewer delta vs own baseline:   {string.format("%.1f", median(perViewerDelta))}`)
