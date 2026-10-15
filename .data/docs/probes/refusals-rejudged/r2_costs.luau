--!strict
--!optimize 2
-- Costs and frame sizes for refusals-rejudged-2 (R26, R27, R32, R37, R38 of research/security-refusals.md).
-- A. Frame bytes by v5.md §4.1 and §4.6, built with a bit writer and checked against golden vectors G4 and G11:
--    a REPORT-only upstream reliable frame (R26), a REKEY-only downstream reliable frame (R27).
-- B. Client cost of a forced REPORT frame: encode plus HalfSipHash-1-3 tag over it (R26); the tag on a 64 B frame
--    for scale (R27's failing-frame PRFs).
-- C. Server per-fit cost of keeping two counters (R37) and per-frame cost of a per-lane frame counter (R38);
--    a per-player counters snapshot with and without those four fields.
-- D. Client decode at the 2^22-element allowance (R32): cheapest element kinds per element, and the charge
--    (subtract and compare) per count.
-- Run: luau -O2 r2_costs.luau ; luau -O2 --codegen r2_costs.luau
local H = require("../security-costs/harness")
local S = require("../security-costs/hsip")

----------------------------------------------------------------------------------------------------------------
-- A. bit writer (LSB first, buffer.writebits order, v5.md §4.1)
type W = { b: buffer, n: number }
local function newW(): W
	return { b = buffer.create(64), n = 0 }
end
local function bits(w: W, v: number, k: number)
	if k > 0 then
		buffer.writebits(w.b, w.n, k, v)
		w.n += k
	end
end
local function eg0(w: W, x: number)
	local v = x + 1
	local z = 0
	while 2 ^ (z + 1) <= v do z += 1 end
	bits(w, 0, z)
	bits(w, 1, 1)
	bits(w, v - 2 ^ z, z)
end
local function align(w: W)
	w.n = math.ceil(w.n / 8) * 8
end
local function bytes(w: W, tail: string?): buffer
	align(w)
	local nb = w.n // 8
	local t = tail or ""
	local out = buffer.create(nb + #t)
	buffer.copy(out, 0, w.b, 0, nb)
	buffer.writestring(out, nb, t)
	return out
end
local function hex(b: buffer): string
	local p = {}
	for i = 0, buffer.len(b) - 1 do p[#p + 1] = string.format("%02x", buffer.readu8(b, i)) end
	return table.concat(p, " ")
end
local function withTag(f: buffer, count: number, lane: number): buffer
	local k0, k1 = 0x03020100, 0x07060504 -- golden key 00 01 .. 07
	local tag = S.tag13(k0, k1, f, buffer.len(f), 1024, count, lane, 0)
	local out = buffer.create(buffer.len(f) + 4)
	buffer.copy(out, 0, f)
	buffer.writeu32(out, buffer.len(f), tag)
	return out
end

-- G4: up reliable, count 0, chat:fire("gg") (up id 1 of 3 -> u(2); string(200) length u8)
do
	local w = newW()
	bits(w, 0, 1) -- ack '0'
	eg0(w, 1) -- one run segment
	eg0(w, 1) -- namespace 1
	eg0(w, 0) -- one chunk
	bits(w, 1, 2) -- id chat
	eg0(w, 0) -- count 1
	bits(w, 2, 8) -- length 2
	local g4 = withTag(bytes(w, "gg"), 0, 0)
	assert(hex(g4) == "a4 15 00 67 67 9e 09 c7 aa", "G4 " .. hex(g4))
	print("check: G4 reproduced: " .. hex(g4))
end
-- G11: down reliable, tick unchanged, one MISMATCH
local function downControl(typ: number, row: (W) -> ()): buffer
	local w = newW()
	bits(w, 0, 1) -- tick unchanged
	eg0(w, 0) -- segs(state) none
	eg0(w, 1) -- one run segment
	eg0(w, 0) -- namespace 0 (control)
	eg0(w, 0) -- one chunk
	eg0(w, 0) -- segs(remove) none
	align(w) -- downstream chunks start on a byte boundary
	bits(w, typ, 3)
	eg0(w, 0) -- one message
	row(w)
	return bytes(w)
end
do
	local g11 = downControl(2, function(_w: W) end)
	assert(hex(g11) == "ea 0a", "G11 " .. hex(g11))
	print("check: G11 reproduced: " .. hex(g11))
end

-- R26: REPORT-only upstream reliable frame. fields = the REPORT row's counts in order.
local function reportFrame(fields: { number }): buffer
	local w = newW()
	bits(w, 0, 1) -- ack '0'
	eg0(w, 1) -- one run segment
	eg0(w, 0) -- namespace 0
	eg0(w, 0) -- one chunk
	bits(w, 5, 3) -- REPORT
	eg0(w, 0) -- one message
	for _, x in fields do eg0(w, x) end
	return bytes(w)
end
print("## A. frame sizes (bytes, tag included upstream; downstream frames carry no tag)")
for _, case in {
	{ "REPORT 3 fields (U7 bit adopted): probes 1, identity 1, refused 0", { 1, 1, 0 } },
	{ "REPORT 3 fields: probes 60, identity 60, refused 0", { 60, 60, 0 } },
	{ "REPORT 3 fields: probes 0, identity 0, refused 1", { 0, 0, 1 } },
	{ "REPORT 3 fields: probes 0, identity 0, refused 80", { 0, 0, 80 } },
	{ "REPORT 4 fields (today): probes 60, 60, 60, refused 0", { 60, 60, 60, 0 } },
} do
	local f = withTag(reportFrame(case[2] :: { number }), 7, 0)
	print(string.format("%-62s %2d B  %s", case[1] :: string, buffer.len(f), hex(f)))
end
local rekey = downControl(3, function(w: W)
	bits(w, 0x03020100, 32)
	bits(w, 0x07060504, 32)
end)
print(string.format("%-62s %2d B  %s", "REKEY-only downstream reliable frame, tick unchanged", buffer.len(rekey), hex(rekey)))

----------------------------------------------------------------------------------------------------------------
-- B. client cost of a forced REPORT frame
local K0, K1 = 0x03020100, 0x07060504
local f3 = reportFrame({ 1, 1, 0 })
local len3 = buffer.len(f3)
local f64 = buffer.create(64)
for i = 0, 63 do buffer.writeu8(f64, i, (i * 37) % 256) end
local scratch = buffer.create(64)
H.compare("B. forced REPORT frame, client side", 200000, {
	{ name = "encode REPORT frame (3 fields)", fn = function(n: number): number
		local s = 0
		for i = 1, n do
			local w = { b = scratch, n = 0 }
			bits(w, 0, 1); eg0(w, 1); eg0(w, 0); eg0(w, 0); bits(w, 5, 3); eg0(w, 0)
			eg0(w, i % 3); eg0(w, i % 2); eg0(w, 0)
			s += w.n
		end
		return s
	end },
	{ name = "tag13 over the 3 B REPORT frame", fn = function(n: number): number
		local s = 0
		for i = 1, n do s += S.tag13(K0, K1, f3, len3, 16384, i, 0, 0) end
		return s
	end },
	{ name = "tag13 over a 64 B frame", fn = function(n: number): number
		local s = 0
		for i = 1, n do s += S.tag13(K0, K1, f64, 64, 16384, i, 0, 0) end
		return s
	end },
})

----------------------------------------------------------------------------------------------------------------
-- C. server counters: per fit (R37), per frame (R38), snapshot
type P = { clockFits: number, clockSlope: number?, framesR: number, framesU: number }
local players: { P } = {}
for i = 1, 100 do players[i] = { clockFits = 0, clockSlope = nil, framesR = 0, framesU = 0 } end
local REASONS = 27
local function snapshot(p: P, extra: boolean): any
	local facts = table.create(0)
	for r = 1, REASONS do facts[r] = r end
	local t: { [string]: any } = {
		messagesSent = 1, messagesReceived = 2, bytesSent = 3, bytesReceived = 4, facts = table.freeze(facts),
		rowsDeferred = 5, validatorErrors = 6, validatorRejections = 7, lateAnswers = 8, heldBytes = 9,
	}
	if extra then
		t.clockFits = p.clockFits
		t.clockSlope = p.clockSlope
		t.framesReceived = table.freeze({ reliable = p.framesR, unreliable = p.framesU })
	end
	return table.freeze(t)
end
H.compare("C. server counters", 1000000, {
	{ name = "per fit: nothing (baseline loop)", fn = function(n: number): number
		local s = 0
		for i = 1, n do s += i % 100 end
		return s
	end },
	{ name = "per fit: clockFits += 1, clockSlope = s", fn = function(n: number): number
		local s = 0
		for i = 1, n do
			local p = players[i % 100 + 1]
			p.clockFits += 1
			p.clockSlope = i * 1e-6
			s += i % 100
		end
		return s
	end },
	{ name = "per frame: framesReceived[lane] += 1", fn = function(n: number): number
		local s = 0
		for i = 1, n do
			local p = players[i % 100 + 1]
			if i % 3 == 0 then p.framesU += 1 else p.framesR += 1 end
			s += i % 100
		end
		return s
	end },
})
H.compare("C. per-player counters snapshot", 100000, {
	{ name = "snapshot, today's fields", fn = function(n: number): number
		local s = 0
		for i = 1, n do s += snapshot(players[i % 100 + 1], false).heldBytes end
		return s
	end },
	{ name = "snapshot + clockFits, clockSlope, framesReceived", fn = function(n: number): number
		local s = 0
		for i = 1, n do s += snapshot(players[i % 100 + 1], true).heldBytes end
		return s
	end },
})

----------------------------------------------------------------------------------------------------------------
-- D. client decode per element for the cheapest element kinds, and the charge per count
local N = 65536
H.compare("D. client decode per 65,536 elements", 20, {
	{ name = "bool column of false (table.create + fill)", fn = function(n: number): number
		local s = 0
		for _ = 1, n do
			local a = table.create(N)
			for j = 1, N do a[j] = false end
			s += #a
		end
		return s
	end },
	{ name = "empty records (a table each)", fn = function(n: number): number
		local s = 0
		for _ = 1, n do
			local a = table.create(N)
			for j = 1, N do a[j] = {} end
			s += #a
		end
		return s
	end },
	{ name = "charge per count: 65,536 counts", fn = function(n: number): number
		-- one subtraction and one comparison per count (a run, array or map count), as v5.md §4.8 charges
		local s = 0
		for _ = 1, n do
			local allowance = 4194304
			for j = 1, N do
				allowance -= j % 7
				if allowance < -1e15 then return -1 end
			end
			s += allowance
		end
		return s
	end },
})
print("sink", H.sink)
