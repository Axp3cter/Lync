--!strict
--!optimize 2
-- R33: what an upstream intern table costs the server. (a) heap per entry of an id -> string array,
-- for strings alive only in the table and for strings already alive elsewhere (Luau interns string
-- contents, so a table entry for a live string is one slot). (b) decoding a reference (an index
-- into the array) against decoding a literal (buffer.readstring of L bytes from the tail).
local H = require("../security-costs/harness")

local function make(i: number, len: number): string
	local digits = tostring(i)
	return string.rep("x", len - #digits) .. digits
end

-- heap growth per entry when an array of n entries is built; `alive` holds the same strings first
local function heapPerEntry(n: number, len: number, alsoAlive: boolean, base: number): number
	local alive: { string } = {}
	if alsoAlive then
		alive = table.create(n)
		for i = 1, n do alive[i] = make(base + i, len) end
	end
	collectgarbage("collect")
	local before = collectgarbage("count")
	local list = table.create(n)
	for i = 1, n do list[i] = make(base + i, len) end
	collectgarbage("collect")
	local after = collectgarbage("count")
	assert(#list == n and (#alive == 0 or #alive == n))
	return (after - before) * 1024 / n
end

for _, len in { 12, 20, 64, 200 } do
	print(string.format("heap per entry, %3d-byte strings, 4096 entries: %6.1f B (string owned by the table), %5.1f B (string alive elsewhere)",
		len, heapPerEntry(4096, len, false, 0), heapPerEntry(4096, len, true, 10000)))
end

local L = 20
local tail = buffer.create(L * 256)
for i = 0, buffer.len(tail) - 1 do buffer.writeu8(tail, i, 65 + i % 26) end
local list = table.create(256)
for i = 1, 256 do list[i] = buffer.readstring(tail, (i - 1) * L, L) end
H.compare("decode one 20-byte string value", 200000, {
	{ name = "literal: buffer.readstring 20 B", fn = function(m)
		local s = 0
		for i = 1, m do s += #buffer.readstring(tail, (i % 256) * L, L) end
		return s
	end },
	{ name = "reference: list[id]", fn = function(m)
		local s = 0
		for i = 1, m do s += #list[i % 256 + 1] end
		return s
	end },
})
