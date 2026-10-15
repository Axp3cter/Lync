--!strict
--!optimize 2
-- Sizes and costs for research/clock-facts.md (U3, the BEACON frame gap, U4).
-- A. Upstream frame bytes by design/v5.md §4.1 and §4.6, with the bit writer of
--    probes/refusals-rejudged/r2_costs.luau, checked first against golden vector G4:
--    a forced BEACON-only reliable frame (ack '0', and ack '1' seq received), BEACON + REPORT, and a BEACON riding G4.
-- B. Client (interpreted is the Roblox client case): encode a BEACON-only frame, HalfSipHash-1-3 tag over it.
-- C. Server per fit and per epoch (U3): the 66-pair fit for scale; the two 15-pair half fits (only for fits beyond
--    the threshold); per epoch, sorting 100 players' slopes; per fact, the leave-one-out median from the sorted array.
-- D. Server per answered ask (U4): result with four timing fields against without; the path bound as the minimum of
--    ten one-second buckets (research/server-facts.md U10.7 measured the same operation).
-- Run: luau -O2 beacon_cost.luau ; luau -O2 --codegen beacon_cost.luau
local H = require("../security-costs/harness")
local S = require("../security-costs/hsip")

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
local function bytes(w: W, tail: string?): buffer
	w.n = math.ceil(w.n / 8) * 8
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
local K0, K1 = 0x03020100, 0x07060504
local function withTag(f: buffer, count: number, lane: number): buffer
	local tag = S.tag13(K0, K1, f, buffer.len(f), 1024, count, lane, 0)
	local out = buffer.create(buffer.len(f) + 4)
	buffer.copy(out, 0, f)
	buffer.writeu32(out, buffer.len(f), tag)
	return out
end

-- G4 check: up reliable, count 0, chat:fire("gg")
local function g4(beacon: number?): buffer
	local w = newW()
	bits(w, 0, 1) -- ack '0'
	if beacon then
		eg0(w, 2) -- two run segments: control (namespace 0), then namespace 1
		eg0(w, 0); eg0(w, 0) -- namespace 0, one chunk
		eg0(w, 1); eg0(w, 0) -- namespace 1, one chunk
		bits(w, 6, 3); eg0(w, 0); bits(w, beacon, 16) -- BEACON
	else
		eg0(w, 1); eg0(w, 1); eg0(w, 0)
	end
	bits(w, 1, 2); eg0(w, 0); bits(w, 2, 8) -- chat, count 1, length 2
	return withTag(bytes(w, "gg"), 0, 0)
end
assert(hex(g4()) == "a4 15 00 67 67 9e 09 c7 aa", "G4 " .. hex(g4()))
print("check: G4 reproduced: " .. hex(g4()))

local function beaconFrame(stamp: number, ack: boolean, report: { number }?): buffer
	local w = newW()
	if ack then
		bits(w, 1, 1); bits(w, 4095, 12); bits(w, 0xFFFF, 16) -- '1' seq:u12 received:u16
	else
		bits(w, 0, 1)
	end
	eg0(w, 1) -- one run segment
	eg0(w, 0) -- namespace 0
	eg0(w, report and 1 or 0) -- chunks - 1
	if report then
		bits(w, 5, 3); eg0(w, 0)
		for _, x in report do eg0(w, x) end
	end
	bits(w, 6, 3) -- BEACON
	eg0(w, 0) -- one message
	bits(w, stamp, 16)
	return withTag(bytes(w), 7, 0)
end
print("## A. upstream frame bytes, tag included")
for _, c in {
	{ "BEACON-only forced frame, ack '0'", beaconFrame(0xBEEF, false, nil) },
	{ "BEACON-only forced frame, ack '1' seq received", beaconFrame(0xBEEF, true, nil) },
	{ "BEACON + REPORT (probes 1, identity 1, refused 0), ack '0'", beaconFrame(0xBEEF, false, { 1, 1, 0 }) },
	{ "G4 (chat 'gg') without BEACON", g4() },
	{ "G4 with a riding BEACON", g4(0xBEEF) },
} do
	local b = c[2] :: buffer
	print(string.format("%-58s %2d B  %s", c[1] :: string, buffer.len(b), hex(b)))
end

-- B. client: encode + tag of a forced BEACON frame
local scratch = buffer.create(64)
local fb = beaconFrame(0xBEEF, false, nil)
local fbody = buffer.create(buffer.len(fb) - 4)
buffer.copy(fbody, 0, fb, 0, buffer.len(fbody))
H.compare("B. forced BEACON frame, client side", 200000, {
	{ name = "encode BEACON-only frame", fn = function(n: number): number
		local s = 0
		for i = 1, n do
			local w = { b = scratch, n = 0 }
			bits(w, 0, 1); eg0(w, 1); eg0(w, 0); eg0(w, 0); bits(w, 6, 3); eg0(w, 0); bits(w, i % 65536, 16)
			s += w.n
		end
		return s
	end },
	{ name = "tag13 over the BEACON frame body", fn = function(n: number): number
		local s = 0
		for i = 1, n do s += S.tag13(K0, K1, fbody, buffer.len(fbody), 16384, i, 0, 0) end
		return s
	end },
})

-- C. server, U3
local NWIN, WIN = 12, 5
local ys = table.create(NWIN, 0)
for i = 1, NWIN do ys[i] = 0.08 + 0.01 * i * WIN + ((i * 37) % 11) * 0.001 end
local s66 = table.create(66, 0)
local s15 = table.create(15, 0)
local function fit66(y: { number }): number
	local k = 0
	for i = 1, NWIN - 1 do
		for j = i + 1, NWIN do
			k += 1
			s66[k] = (y[j] - y[i]) / (WIN * (j - i))
		end
	end
	table.sort(s66)
	return (s66[33] + s66[34]) / 2
end
local function fit15(y: { number }, first: number): number
	local k = 0
	for i = first, first + 4 do
		for j = i + 1, first + 5 do
			k += 1
			s15[k] = (y[j] - y[i]) / (WIN * (j - i))
		end
	end
	table.sort(s15)
	return s15[8]
end
local N = 100
local fits = table.create(N, 0)
local sorted = table.create(N, 0)
local function fillFits(seed: number)
	for i = 1, N do fits[i] = ((i * 7919 + seed) % 997) / 997 * 0.002 - 0.001 end
end
-- leave-one-out median of sorted[1..n] without the element at index r (r found by the caller once per fact)
local function loo(n: number, r: number): number
	local m = n - 1
	local function at(k: number): number -- k-th of the n - 1 others
		return sorted[k < r and k or k + 1]
	end
	if m % 2 == 1 then return at((m + 1) // 2) end
	return (at(m // 2) + at(m // 2 + 1)) / 2
end
local res = H.compare("C. server, per fit and per epoch (U3)", 20000, {
	{ name = "66-pair fit (today, for scale)", fn = function(n: number): number
		local s = 0
		for i = 1, n do ys[1] = i * 1e-9; s += fit66(ys) end
		return s
	end },
	{ name = "two 15-pair half fits", fn = function(n: number): number
		local s = 0
		for i = 1, n do ys[1] = i * 1e-9; s += fit15(ys, 1) + fit15(ys, 7) end
		return s
	end },
	{ name = "epoch: copy + sort 100 slopes", fn = function(n: number): number
		local s = 0
		for i = 1, n do
			fillFits(i % 64)
			table.move(fits, 1, N, 1, sorted)
			table.sort(sorted)
			s += sorted[50]
		end
		return s
	end },
	{ name = "epoch: fill only (setup)", fn = function(n: number): number
		for i = 1, n do fillFits(i % 64) end
		return fits[1]
	end },
	{ name = "per fact: find rank + leave-one-out median", fn = function(n: number): number
		local s = 0
		for i = 1, n do
			local x = sorted[(i % N) + 1]
			-- binary search for the rank of x
			local lo, hi = 1, N
			while lo < hi do
				local mid = (lo + hi) // 2
				if sorted[mid] < x then lo = mid + 1 else hi = mid end
			end
			s += loo(N, lo)
		end
		return s
	end },
})
local sortNet = res["epoch: copy + sort 100 slopes"] - res["epoch: fill only (setup)"]
print(string.format("epoch sort net of setup: %.0f ns; at one epoch per 5 s: %.3f us/s", sortNet, sortNet / 5 / 1000))

-- D. server, U4
local sendAt = table.create(16, 0)
local pingAt = table.create(16, 0)
local buckets = table.create(10, 0.1)
H.compare("D. server, per answered ask (U4)", 1000000, {
	{ name = "result { ok, value }", fn = function(n: number): number
		local s = 0
		for i = 1, n do
			local r = { ok = true, value = i }
			s += r.value
		end
		return s
	end },
	{ name = "result + 4 timing fields", fn = function(n: number): number
		local s = 0
		for i = 1, n do
			local slot = i % 16 + 1
			local r = { ok = true, value = i, roundTrip = 0.2 - sendAt[slot], pingAtAsk = pingAt[slot], pingAtAnswer = 0.05, minPing = 0.04 }
			s += r.value
		end
		return s
	end },
	{ name = "bound: min of 10 one-second buckets", fn = function(n: number): number
		local s = 0
		for i = 1, n do
			buckets[i % 10 + 1] = 0.05 + (i % 7) * 0.001
			local m = math.huge
			for k = 1, 10 do
				local v = buckets[k]
				if v < m then m = v end
			end
			s += m
		end
		return s
	end },
	{ name = "record send time + ping in slot", fn = function(n: number): number
		for i = 1, n do
			local slot = i % 16 + 1
			sendAt[slot] = i * 1e-6
			pingAt[slot] = 0.05
		end
		return sendAt[1]
	end },
})
print("sink", H.sink)
