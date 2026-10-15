--!strict
-- Claim: the 16-bit HalfSipHash-1-3 tag over counter + length + the first `cover` bytes (design §6.2,
-- default cover = 1024) costs the interpreted client a fixed part plus a per-byte part per upstream
-- reliable frame. client-security §3.1 estimated, without measuring, 0.2-0.3 us fixed plus 13-23 ns
-- per covered byte interpreted. This probe measures it.
-- Implementation: 32-bit ARX with bit32 builtins and buffer.readu32, one compression round per
-- 4-byte word, three finalisation rounds, output truncated to 16 bits. Constants follow the
-- reference halfsiphash.c; exact test vectors are not checked (cost only).
-- Run: luau -O2 halfsiphash_cost.luau ; luau -O2 --codegen halfsiphash_cost.luau

local lrot, bxor, band = bit32.lrotate, bit32.bxor, bit32.band

local function tag(k0: number, k1: number, counter: number, b: buffer, len: number, cover: number): number
	local v0, v1 = k0, k1
	local v2, v3 = bxor(0x6c796765, k0), bxor(0x74656462, k1)
	local n = math.min(len, cover)
	-- word 0: counter; word 1: length
	local m = counter
	for w = -1, n // 4 - 1 do
		if w == -1 then
			m = counter
		elseif w == 0 and false then
			m = len
		else
			m = buffer.readu32(b, w * 4)
		end
		v3 = bxor(v3, m)
		-- one SipRound (c = 1)
		v0 += v1
		v1 = lrot(v1, 5)
		v1 = bxor(v1, v0)
		v0 = lrot(v0, 16)
		v2 += v3
		v3 = lrot(v3, 8)
		v3 = bxor(v3, v2)
		v0 += v3
		v3 = lrot(v3, 7)
		v3 = bxor(v3, v0)
		v2 += v1
		v1 = lrot(v1, 13)
		v1 = bxor(v1, v2)
		v2 = lrot(v2, 16)
		v0 = bxor(v0, m)
	end
	-- tail + length word
	local last = bit32.lshift(band(len, 0xff), 24)
	for i = (n // 4) * 4, n - 1 do
		last = bit32.bor(last, bit32.lshift(buffer.readu8(b, i), 8 * (i % 4)))
	end
	v3 = bxor(v3, last)
	v0 += v1; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
	v2 += v3; v3 = lrot(v3, 8); v3 = bxor(v3, v2); v0 += v3
	v3 = lrot(v3, 7); v3 = bxor(v3, v0); v2 += v1; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	v0 = bxor(v0, last)
	v2 = bxor(v2, 0xff)
	for _ = 1, 3 do
		v0 += v1; v1 = lrot(v1, 5); v1 = bxor(v1, v0); v0 = lrot(v0, 16)
		v2 += v3; v3 = lrot(v3, 8); v3 = bxor(v3, v2); v0 += v3
		v3 = lrot(v3, 7); v3 = bxor(v3, v0); v2 += v1; v1 = lrot(v1, 13); v1 = bxor(v1, v2); v2 = lrot(v2, 16)
	end
	return band(bxor(v1, v3), 0xffff)
end

local sink = 0
print("frameBytes\tcover\tmedian us/frame\tmin\tmax")
for _, size in { 0, 16, 64, 256, 1024 } do
	local b = buffer.create(math.max(size, 4))
	for i = 0, size - 1 do
		buffer.writeu8(b, i, (i * 37) % 256)
	end
	local N = if size >= 256 then 20000 else 100000
	local times = {}
	for _ = 1, 7 do
		local t0 = os.clock()
		for i = 1, N do
			sink = bxor(sink, tag(0x12345678, 0x9abcdef0, i, b, size, 1024))
		end
		table.insert(times, (os.clock() - t0) / N * 1e6)
	end
	table.sort(times)
	print(string.format("%d\t1024\t%.3f\t%.3f\t%.3f", size, times[4], times[1], times[7]))
end
print("sink", sink)
