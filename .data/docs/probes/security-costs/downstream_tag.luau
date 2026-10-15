--!strict
-- Claim 3: "Downstream tags: a PRF per recipient costs <= 3% of a core and ends FireAllClients"
-- (v5-changes.md:102, :555; R1). Server cost per downstream frame sent to 100 recipients, by frame size:
--   per-recipient HalfSipHash-1-3 over the whole frame (generated loop; unrolled x4 nested form);
--   tag once per frame (64-bit HalfSipHash-1-3 under a per-frame server key) + per recipient a 2-word PRF of
--   (digest xor that recipient's count) under its own key;
--   per-recipient tag over the header only (cover 16 B) and over the counter only (cover 0);
--   per-recipient buffer.copy of the frame, the CLI-visible part of leaving FireAllClients (the engine's
--   per-call cost is not measurable here).
-- Run: luau -O2 downstream_tag.luau ; luau -O2 --codegen downstream_tag.luau
local H = require("./harness")
local S = require("./hsip")
assert(S.check() > 0)

local P = 100
local keys0, keys1, counts = table.create(P, 0), table.create(P, 0), table.create(P, 0)
for r = 1, P do
	keys0[r] = (r * 2654435761) % 2 ^ 32
	keys1[r] = (r * 40503 + 7) % 2 ^ 32
	counts[r] = r * 13
end
local outs = table.create(P)
local results: { [number]: { [string]: number } } = {}
local SIZES = { 32, 64, 128, 256, 512, 1024, 4096 }
for _, size in SIZES do
	local b = buffer.create(size + 4)
	for i = 0, size - 1 do
		buffer.writeu8(b, i, (i * 31 + 5) % 256)
	end
	for r = 1, P do
		outs[r] = buffer.create(size + 4)
	end
	local iters = math.max(20, 60000 // (size + 64))
	results[size] = H.compare(string.format("downstream frame of %d B to %d recipients (time per frame)", size, P), iters, {
		{ name = "per recipient, generated loop", fn = function(n)
			local s = 0
			for _ = 1, n do
				for r = 1, P do
					s = bit32.bxor(s, S.tag13(keys0[r], keys1[r], b, size, 16384, counts[r], 0, 0))
				end
			end
			return s
		end },
		{ name = "per recipient, unrolled x4", fn = function(n)
			local s = 0
			for _ = 1, n do
				for r = 1, P do
					s = bit32.bxor(s, S.tag13u4(keys0[r], keys1[r], b, size, 16384, counts[r], 0, 0))
				end
			end
			return s
		end },
		{ name = "once per frame + per-recipient mix", fn = function(n)
			local s = 0
			for i = 1, n do
				local h0, h1 = S.tagcd(0x9e3779b9, i, b, size, 16384, i, 0, 0, 1, 3, true)
				for r = 1, P do
					s = bit32.bxor(s, S.prf2(keys0[r], keys1[r], bit32.bxor(h0, counts[r]), h1))
				end
			end
			return s
		end },
		{ name = "per recipient, header only (16 B)", fn = function(n)
			local s = 0
			for _ = 1, n do
				for r = 1, P do
					s = bit32.bxor(s, S.tag13u4(keys0[r], keys1[r], b, size, 16, counts[r], 0, 0))
				end
			end
			return s
		end },
		{ name = "per recipient, counter only", fn = function(n)
			local s = 0
			for _ = 1, n do
				for r = 1, P do
					s = bit32.bxor(s, S.tag13u4(keys0[r], keys1[r], b, size, 0, counts[r], 0, 0))
				end
			end
			return s
		end },
		{ name = "per recipient buffer.copy only", fn = function(n)
			for _ = 1, n do
				for r = 1, P do
					buffer.copy(outs[r], 0, b, 0, size)
				end
			end
			return buffer.readu8(outs[P], 0)
		end },
	})
end

print("## share of one core for 100 players, 80 downstream frames/s each (busy model: 60 reliable + 20 unreliable), and at 60/s")
for _, size in SIZES do
	local row = {}
	for _, name in { "per recipient, generated loop", "per recipient, unrolled x4", "once per frame + per-recipient mix", "per recipient, header only (16 B)", "per recipient, counter only", "per recipient buffer.copy only" } do
		local ns = results[size][name]
		table.insert(row, string.format("%s %.2f%%/%.2f%%", name, ns * 80 / 1e7, ns * 60 / 1e7))
	end
	print(string.format("%5d B: %s", size, table.concat(row, "; ")))
end
print("sink", H.sink)
