--!strict
--!optimize 2
-- M3 cost per field: an 8-field record of bounded codes, encoded and decoded plain (seed 0) and with per-build code
-- offsets folded in as constants. Fields: a n=256, b n=101, c bool, d n=4096, e n=5, f n=65536, g n=30, h n=3.
-- Encode and decode are timed separately; variants are interleaved over rounds and the best round is kept.
-- Run: luau -O2 offsets.luau   and   luau -O2 --codegen offsets.luau
type R = { a: number, b: number, c: boolean, d: number, e: number, f: number, g: number, h: number }
local band, bxor = bit32.band, bit32.bxor
local wb, rb = buffer.writebits, buffer.readbits

local function encP(b: buffer, bit: number, r: R): number
	wb(b, bit, 8, r.a); wb(b, bit + 8, 7, r.b); wb(b, bit + 15, 1, if r.c then 1 else 0); wb(b, bit + 16, 12, r.d)
	wb(b, bit + 28, 3, r.e); wb(b, bit + 31, 16, r.f); wb(b, bit + 47, 5, r.g); wb(b, bit + 52, 2, r.h)
	return bit + 54
end
local function decP(b: buffer, bit: number): R
	return { a = rb(b, bit, 8), b = rb(b, bit + 8, 7), c = rb(b, bit + 15, 1) == 1, d = rb(b, bit + 16, 12),
		e = rb(b, bit + 28, 3), f = rb(b, bit + 31, 16), g = rb(b, bit + 47, 5), h = rb(b, bit + 52, 2) }
end
-- offsets: a 173, b 58, c 1, d 3001, e 2, f 40961, g 17, h 1
local function encO(b: buffer, bit: number, r: R): number
	wb(b, bit, 8, band(r.a + 173, 255))
	local x = r.b + 58; if x >= 101 then x -= 101 end; wb(b, bit + 8, 7, x)
	wb(b, bit + 15, 1, if r.c then 0 else 1)
	wb(b, bit + 16, 12, band(r.d + 3001, 4095))
	x = r.e + 2; if x >= 5 then x -= 5 end; wb(b, bit + 28, 3, x)
	wb(b, bit + 31, 16, band(r.f + 40961, 65535))
	x = r.g + 17; if x >= 30 then x -= 30 end; wb(b, bit + 47, 5, x)
	x = r.h + 1; if x >= 3 then x -= 3 end; wb(b, bit + 52, 2, x)
	return bit + 54
end
local function decO(b: buffer, bit: number): R
	local xb = rb(b, bit + 8, 7) - 58; if xb < 0 then xb += 101 end
	local xe = rb(b, bit + 28, 3) - 2; if xe < 0 then xe += 5 end
	local xg = rb(b, bit + 47, 5) - 17; if xg < 0 then xg += 30 end
	local xh = rb(b, bit + 52, 2) - 1; if xh < 0 then xh += 3 end
	return { a = band(rb(b, bit, 8) - 173, 255), b = xb, c = rb(b, bit + 15, 1) == 0, d = band(rb(b, bit + 16, 12) - 3001, 4095),
		e = xe, f = band(rb(b, bit + 31, 16) - 40961, 65535), g = xg, h = xh }
end

local N = 1_000_000
local buf = buffer.create(16)
local rec: R = { a = 200, b = 77, c = true, d = 1234, e = 4, f = 60000, g = 29, h = 2 }
local best = { eP = math.huge, eO = math.huge, dP = math.huge, dO = math.huge }
local function timeEnc(enc: (buffer, number, R) -> number): number
	local t0 = os.clock(); for _ = 1, N do enc(buf, 0, rec) end; return os.clock() - t0
end
local function timeDec(dec: (buffer, number) -> R): number
	local t0 = os.clock(); for _ = 1, N do dec(buf, 0) end; return os.clock() - t0
end
for _ = 1, 9 do
	best.eP = math.min(best.eP, timeEnc(encP)); encP(buf, 0, rec); best.dP = math.min(best.dP, timeDec(decP))
	best.eO = math.min(best.eO, timeEnc(encO)); encO(buf, 0, rec); best.dO = math.min(best.dO, timeDec(decO))
end
local function ns(t: number): number return t / N * 1e9 end
print(string.format("encode plain %6.1f ns, offsets %6.1f ns: +%.1f ns per record, +%.2f ns per field", ns(best.eP), ns(best.eO), ns(best.eO - best.eP), ns(best.eO - best.eP) / 8))
print(string.format("decode plain %6.1f ns, offsets %6.1f ns: +%.1f ns per record, +%.2f ns per field", ns(best.dP), ns(best.dO), ns(best.dO - best.dP), ns(best.dO - best.dP) / 8))
-- exhaustive round trip on every field's codes
for v = 0, 65535 do
	local r2: R = { a = v % 256, b = v % 101, c = v % 2 == 0, d = v % 4096, e = v % 5, f = v, g = v % 30, h = v % 3 }
	encO(buf, 0, r2)
	local d = decO(buf, 0)
	for k, x in r2 :: any do assert((d :: any)[k] == x, "round trip " .. k .. " " .. v) end
end
print("offset round trip: every code of every field ok")
