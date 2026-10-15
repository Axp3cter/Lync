--!strict
-- Claim 8: "tag.cover 16,384 B default: <= 0.23 ms/s per player on the server; 0.022 us/B interpreted, 0.0035
-- native" (v5.md §7.5 tag.cover row, v5-changes.md:549). Claim 11 (b, c): HalfSipHash 2-4 "about twice the
-- per-byte cost" (client-security.md §3.1) and a 64-bit tag's "longer finalization" (v5.md §4.5, R28).
-- Per frame size: the generated HalfSipHash-1-3 tag (v5.md §4.5 layout, hsip.tag13, baseline), the same with the
-- word loop unrolled by 4 (hsip.tag13u4), 2-4 rounds, and 1-3 with the 64-bit output.
-- Run: luau -O2 tag_cover.luau ; luau -O2 --codegen tag_cover.luau
local H = require("./harness")
local S = require("./hsip")

print("check: fast HalfSipHash matches the reference port on " .. S.check() .. " frames (1-3/32, 2-4/32, 1-3/64)")

local K0, K1 = 0x03020100, 0x07060504
local res: { [number]: { [string]: number } } = {}
local SIZES = { 0, 16, 64, 256, 1024, 4096, 16384 }
for _, size in SIZES do
	local b = buffer.create(size + 4)
	for i = 0, size - 1 do
		buffer.writeu8(b, i, (i * 37 + 11) % 256)
	end
	local iters = math.max(400, 3000000 // (size + 64))
	res[size] = H.compare(string.format("tag over a %d B frame, cover 16384", size), iters, {
		{ name = "1-3/32 generated loop", fn = function(n)
			local s = 0
			for i = 1, n do s = bit32.bxor(s, S.tag13(K0, K1, b, size, 16384, i, 0, 0)) end
			return s
		end },
		{ name = "1-3/32 unrolled x4", fn = function(n)
			local s = 0
			for i = 1, n do s = bit32.bxor(s, S.tag13u4(K0, K1, b, size, 16384, i, 0, 0)) end
			return s
		end },
		{ name = "2-4/32", fn = function(n)
			local s = 0
			for i = 1, n do s = bit32.bxor(s, (S.tagcd(K0, K1, b, size, 16384, i, 0, 0, 2, 4, false))) end
			return s
		end },
		{ name = "1-3/64", fn = function(n)
			local s = 0
			for i = 1, n do
				local a, c = S.tagcd(K0, K1, b, size, 16384, i, 0, 0, 1, 3, true)
				s = bit32.bxor(s, a, c)
			end
			return s
		end },
		{ name = "1-3/32 tagcd (same, generic loop)", fn = function(n)
			local s = 0
			for i = 1, n do s = bit32.bxor(s, (S.tagcd(K0, K1, b, size, 16384, i, 0, 0, 1, 3, false))) end
			return s
		end },
	})
end

print("## derived (medians above)")
for _, name in { "1-3/32 generated loop", "1-3/32 unrolled x4", "2-4/32", "1-3/64" } do
	local fixed = res[0][name]
	local perB = (res[16384][name] - res[1024][name]) / (16384 - 1024)
	local per64 = (res[64][name] - res[0][name]) / 64
	local per1024 = res[1024][name] / 1024
	-- at the default inbound byte budgets (2 lanes x 32,768 B/s) and frame budgets (120 + 240 frames/s)
	local budget = (65536 * perB + 360 * fixed) / 1e6
	print(string.format("%-24s fixed %7.1f ns; marginal %6.2f ns/B (1024..16384); %6.2f ns/B over 0..64; whole-1024 %6.2f ns/B; budget bound %.3f ms/s per player (65,536 B/s + 360 frames/s)",
		name, fixed, perB, per64, per1024, budget))
end
print("sink", H.sink)
