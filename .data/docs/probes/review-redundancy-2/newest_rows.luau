--!strict
-- Claim (design 2 §5.3): ":newest() rows are encoded once per tick and a viewer's frame is buffer.copy of
-- byte-aligned row chunks" is the cheap option. Alternative: quantize once per tick (integer codes per
-- record, shared by all viewers) and bit-pack the selected rows per viewer, bit-contiguous, which is also
-- 5.4-8% smaller (probes/design-2/newest_layout.out: abs_row_bits against abs_row_byte).
-- Row: the §3.4 fighters record's :newest() fields plus its address: slot 6 + generation 2 +
-- position 3 x 17 + rotation 30 (flag 1, index 2, 3 x 9) = 89 bits; 12 B when byte-aligned.
-- Per tick, per viewer, SEL of R records are selected (non-contiguous, as notify and the budget select).
--   copy  : rows encoded once into a 12 B-stride shared buffer (encode cost reported separately, it is
--           paid once per tick), then buffer.copy of each selected row into the viewer's frame.
--   pack  : codes quantized once into a shared buffer of u32 words (paid once per tick), then the
--           viewer's selected rows written bit-contiguously with an accumulator.
-- Reports ns per (viewer, row) and bytes per row. Run: luau -O2 [--codegen] newest_rows.luau

local R, SEL, VIEWERS, REPS = 64, 32, 100, 7

local band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

-- quantized codes per record: word0 = slot|gen (8 bits), x, y, z (17 bits each), rot (30 bits)
local codes = buffer.create(R * 5 * 4)
local seed = 11
local function rnd(n: number): number
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed % n
end
for r = 0, R - 1 do
	buffer.writeu32(codes, r * 20, r * 4 + 1)
	buffer.writeu32(codes, r * 20 + 4, rnd(131072))
	buffer.writeu32(codes, r * 20 + 8, rnd(131072))
	buffer.writeu32(codes, r * 20 + 12, rnd(131072))
	buffer.writeu32(codes, r * 20 + 16, rnd(1073741824))
end

-- selection per viewer: SEL distinct record indices, sorted (non-contiguous)
local sel: { { number } } = {}
for v = 1, VIEWERS do
	local s = {}
	for r = 0, R - 1 do
		if (r * 7 + v * 13) % R < SEL then
			table.insert(s, r)
		end
	end
	sel[v] = s
end

local shared = buffer.create(R * 12)
local frame = buffer.create(R * 16 + 8)

-- bit writer state (module-level locals; inlined manually in loops for fairness)
local function encodeOnce()
	for r = 0, R - 1 do
		local o = r * 12
		local acc, nb, pos = 0, 0, o
		local function put(v: number, n: number)
			if nb + n >= 32 then
				buffer.writeu32(shared, pos, bor(acc, lshift(v, nb)))
				pos += 4
				acc = if nb == 0 then 0 else rshift(v, 32 - nb)
				nb = nb + n - 32
			else
				acc = bor(acc, lshift(v, nb))
				nb += n
			end
		end
		put(buffer.readu32(codes, r * 20), 8)
		put(buffer.readu32(codes, r * 20 + 4), 17)
		put(buffer.readu32(codes, r * 20 + 8), 17)
		put(buffer.readu32(codes, r * 20 + 12), 17)
		put(buffer.readu32(codes, r * 20 + 16), 30)
		-- 89 bits: 2 words written, 25 bits left in acc -> write 4 bytes (the chunk is 12 B)
		buffer.writeu32(shared, pos, acc)
	end
end

local function copyViewers(): number
	local used = 0
	for v = 1, VIEWERS do
		local s = sel[v]
		used = 0
		for i = 1, #s do
			buffer.copy(frame, used, shared, s[i] * 12, 12)
			used += 12
		end
	end
	return used
end

local function packViewers(): number
	local bits = 0
	for v = 1, VIEWERS do
		local s = sel[v]
		local acc, nb, pos = 0, 0, 0
		for i = 1, #s do
			local c = s[i] * 20
			-- 8 bits
			local x = buffer.readu32(codes, c)
			acc = bor(acc, lshift(x, nb))
			nb += 8
			if nb >= 32 then
				buffer.writeu32(frame, pos, acc)
				pos += 4
				nb -= 32
				acc = if nb == 0 then 0 else rshift(x, 8 - nb)
			end
			for k = 1, 3 do
				local y = buffer.readu32(codes, c + k * 4)
				if nb + 17 >= 32 then
					buffer.writeu32(frame, pos, bor(acc, lshift(y, nb)))
					pos += 4
					acc = if nb == 0 then 0 else rshift(y, 32 - nb)
					nb = nb + 17 - 32
				else
					acc = bor(acc, lshift(y, nb))
					nb += 17
				end
			end
			local z = buffer.readu32(codes, c + 16)
			if nb + 30 >= 32 then
				buffer.writeu32(frame, pos, bor(acc, lshift(z, nb)))
				pos += 4
				acc = if nb == 0 then 0 else rshift(z, 32 - nb)
				nb = nb + 30 - 32
			else
				acc = bor(acc, lshift(z, nb))
				nb += 30
			end
		end
		buffer.writeu32(frame, pos, acc)
		bits = pos * 8 + nb
	end
	return bits
end

local function bench(name: string, f: () -> any, perUnit: number)
	local times = {}
	local out
	for _ = 1, REPS do
		local t0 = os.clock()
		for _ = 1, 50 do
			out = f()
		end
		table.insert(times, (os.clock() - t0) / 50 / perUnit * 1e9)
	end
	table.sort(times)
	print(string.format("%-22s median %6.1f ns  (min %6.1f, max %6.1f)  last=%s", name, times[4], times[1], times[#times], tostring(out)))
end

local rowsPerTick = 0
for v = 1, VIEWERS do
	rowsPerTick += #sel[v]
end
print(string.format("records %d, viewers %d, selected rows per tick %d (%.1f per viewer)", R, VIEWERS, rowsPerTick, rowsPerTick / VIEWERS))
bench("encode once (per rec)", function()
	encodeOnce()
	return R
end, R)
bench("copy (per viewer-row)", copyViewers, rowsPerTick)
bench("pack (per viewer-row)", packViewers, rowsPerTick)
print(string.format("bytes per row: copy 12.0, pack %.3f", 89 / 8))
