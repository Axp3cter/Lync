--!strict
--!optimize 2
-- M15 costs: what a build-generated trap, decoy or canary costs at run time on the server.
-- (a) canary per add as specified today: 12 characters of [A-Za-z0-9] from Random.
-- (b) per-viewer canary suffix: 4 characters carrying the viewer id masked by a keyed PRF over (slot, adds).
-- (c) placing a per-viewer canary into a copy of an add piece: buffer.copy of a 32 B piece plus writestring of 12 B.
-- (d) decoy values: clone a real record and offset its position (copy-and-update) against drawing each field
--     uniformly in its codec range.
-- (e) id-width arithmetic for generated trap definitions in the up space.
-- Run: luau -O2 generated_integrity.luau   and   luau -O2 --codegen generated_integrity.luau
local band, bor, bxor, lrotate = bit32.band, bit32.bor, bit32.bxor, bit32.lrotate

local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
local ALPHA_BYTES = table.create(62, 0)
for i = 1, 62 do ALPHA_BYTES[i] = string.byte(ALPHA, i) end

-- Roblox's Random is not in the CLI; math.random stands in (a builtin fast call, so (a) is a lower bound).
math.randomseed(1)
local rand = math.random
local function nextNumber(a: number, b: number): number return a + (b - a) * rand() end
local function canaryRandom(): string
	local c = ALPHA_BYTES
	return string.char(
		c[rand(1, 62)], c[rand(1, 62)], c[rand(1, 62)], c[rand(1, 62)],
		c[rand(1, 62)], c[rand(1, 62)], c[rand(1, 62)], c[rand(1, 62)],
		c[rand(1, 62)], c[rand(1, 62)], c[rand(1, 62)], c[rand(1, 62)]
	)
end

-- HalfSipHash-1-3, 32-bit output, over two u32 words (8-byte message), key (k0, k1); rounds written out
local function hsip13(k0: number, k1: number, m0: number, m1: number): number
	local v0, v1, v2, v3 = k0, k1, bxor(k0, 0x6c796765), bxor(k1, 0x74656462)
	local m = m0
	for r = 1, 6 do
		if r <= 3 then v3 = bxor(v3, m) end
		v0 = band(v0 + v1, 0xffffffff); v1 = bxor(lrotate(v1, 5), v0); v0 = lrotate(v0, 16)
		v2 = band(v2 + v3, 0xffffffff); v3 = bxor(lrotate(v3, 8), v2)
		v0 = band(v0 + v3, 0xffffffff); v3 = bxor(lrotate(v3, 7), v0)
		v2 = band(v2 + v1, 0xffffffff); v1 = bxor(lrotate(v1, 13), v2); v2 = lrotate(v2, 16)
		if r <= 3 then
			v0 = bxor(v0, m)
			m = if r == 1 then m1 else 0x08000000
			if r == 3 then v2 = bxor(v2, 0xff) end
		end
	end
	return bxor(v1, v3)
end

-- (b) a canary is 8 shared characters (one value per record per server, as today) plus a 4-character suffix
-- that carries the viewer's join number masked by HalfSipHash-1-3 keyed by a server-only key over (slot, adds):
-- one PRF per (viewer, add) to send, one PRF per hit to recover the viewer. Its send cost is measured here.
local K0, K1 = 0x0123abcd, 0x7766ff01
local function canarySuffix(slot: number, adds: number, viewerId: number): string
	local c = ALPHA_BYTES
	local x = band(bxor(hsip13(K0, K1, slot, adds), viewerId), 0x7fffff) -- 23 bits: 62^4 > 2^23
	return string.char(c[x % 62 + 1], c[x // 62 % 62 + 1], c[x // 3844 % 62 + 1], c[x // 238328 % 62 + 1])
end
local function recoverViewer(slot: number, adds: number, suffix: string): number
	local a, b, c, d = string.byte(suffix, 1, 4)
	local function idx(ch: number): number return string.find(ALPHA, string.char(ch), 1, true) :: number - 1 end
	local x = idx(a) + 62 * idx(b) + 3844 * idx(c) + 238328 * idx(d)
	return band(bxor(x, band(hsip13(K0, K1, slot, adds), 0x7fffff)), 0x7fffff)
end
assert(recoverViewer(17, 3, canarySuffix(17, 3, 4242)) == 4242, "suffix round trip")
for v = 0, 2000 do assert(recoverViewer(v % 1024, v, canarySuffix(v % 1024, v, v * 37)) == v * 37) end

local piece = buffer.create(32)
local out = buffer.create(4096)
local function placeCanary(dst: number, value: string)
	buffer.copy(out, dst, piece, 0, 32)
	buffer.writestring(out, dst + 14, value)
end

type Rec = { x: number, y: number, z: number, health: number, team: number, ammo: number }
local real: Rec = { x = 120.5, y = 4, z = -88.25, health = 87, team = 2, ammo = 31 }
local function decoyClone(dx: number, dz: number): Rec
	local r = table.clone(real)
	r.x += dx; r.z += dz
	return r
end
local function decoyUniform(): Rec
	return {
		x = nextNumber(-2048, 2048), y = nextNumber(0, 512), z = nextNumber(-2048, 2048),
		health = rand(0, 100), team = rand(1, 4), ammo = rand(0, 255),
	}
end

local N = 400_000
local function bench(name: string, f: (number) -> ())
	local best = math.huge
	for _ = 1, 7 do
		local t0 = os.clock()
		for i = 1, N do f(i) end
		best = math.min(best, os.clock() - t0)
	end
	print(string.format("%-58s %7.1f ns", name, best / N * 1e9))
end

local sink: any = nil
bench("(a) canary, 12 random characters (today)", function(_) sink = canaryRandom() end)
bench("(b) per-viewer canary suffix, 1 x HalfSipHash-1-3 + 4 chars", function(i) sink = canarySuffix(i % 1024, i, i % 100) end)
bench("(b2) recover the viewer from an echoed suffix", function(i) sink = recoverViewer(i % 1024, i, "AbCd") end)
bench("(c) per-viewer add copy, 32 B piece + 12 B canary", function(i) placeCanary((i % 100) * 32, "AbCdEfGhIjKl") end)
bench("(d1) decoy record by clone-and-offset of a real record", function(i) sink = decoyClone(i % 7, 3) end)
bench("(d2) decoy record drawn uniformly per field", function(_) sink = decoyUniform() end)
local _ = sink

print("(e) up-space id bits with T generated traps: D -> bits for T = 0, 1, 2, 4, 8")
local function w(n: number): number return if n <= 1 then 0 else math.ceil(math.log(n, 2) - 1e-12) end
for _, d in { 7, 8, 20, 32, 50, 200 } do
	print(string.format("    D = %3d: %d %d %d %d %d", d, w(d), w(d + 1), w(d + 2), w(d + 4), w(d + 8)))
end
