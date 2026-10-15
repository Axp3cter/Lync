--!strict
-- Bits.write is a wrapper around a local `write` the compiler declines to inline (remarks: "inlining
-- failed: too expensive (cost 56)"), and Bits.read's `windowAt` is not inlined either (cost 37):
-- every field costs two calls. This compares them with the same code with the body in place.
--   luau -O2 p7_bits_calls.bench.luau ; luau -O2 --codegen p7_bits_calls.bench.luau
local Bits = require("../../../../src/wire/bits")

const N = 4096
const ROUNDS = 30

-- Bits.read with windowAt's fast path written in place.
local function readInline(r: Bits.Reader, width: number): number?
	local bit = r.bit
	local finish = bit + width
	if finish > r.stop * 8 then
		return nil
	end
	r.bit = finish
	local buf = r.buf
	local byte = bit // 8
	if width <= 24 and byte + 4 <= buffer.len(buf) then
		if width == 0 then
			return 0
		end
		return bit32.extract(buffer.readu32(buf, byte), bit % 8, width)
	end
	r.bit = bit
	return Bits.read(r, width)
end

-- Bits.write's body, with no wrapper hop.
local function writeInline(w: Bits.Writer, width: number, value: number)
	local bit = w.bit
	if width <= 24 and (bit + width) // 8 + 4 <= buffer.len(w.buf) then
		local buf = w.buf
		local byte = bit // 8
		local shift = bit % 8
		local below = bit32.band(buffer.readu32(buf, byte), bit32.lshift(1, shift) - 1)
		buffer.writeu32(buf, byte, bit32.bor(below, bit32.lshift(value, shift)))
		w.bit = bit + width
		return
	end
	Bits.write(w, width, value)
end

local w = Bits.writer()
for i = 1, N do
	Bits.write(w, 8, i % 256)
end
local bytes = Bits.finish(w)

local best = { math.huge, math.huge, math.huge, math.huge }
for _ = 1, ROUNDS do
	local t0 = os.clock()
	local r = Bits.reader(bytes)
	for _ = 1, N do Bits.read(r, 8) end
	best[1] = math.min(best[1], os.clock() - t0)

	t0 = os.clock()
	r = Bits.reader(bytes)
	for _ = 1, N do readInline(r, 8) end
	best[2] = math.min(best[2], os.clock() - t0)

	t0 = os.clock()
	w.bit = 0
	for i = 1, N do Bits.write(w, 8, i % 256) end
	best[3] = math.min(best[3], os.clock() - t0)

	t0 = os.clock()
	w.bit = 0
	for i = 1, N do writeInline(w, 8, i % 256) end
	best[4] = math.min(best[4], os.clock() - t0)
end
-- Same results.
local a, b = Bits.reader(bytes), Bits.reader(bytes)
for _ = 1, N do assert(Bits.read(a, 8) == readInline(b, 8)) end

print(string.format("read u8: Bits.read %.1f ns, in place %.1f ns; write u8: Bits.write %.1f ns, in place %.1f ns",
	best[1] * 1e9 / N, best[2] * 1e9 / N, best[3] * 1e9 / N, best[4] * 1e9 / N))
