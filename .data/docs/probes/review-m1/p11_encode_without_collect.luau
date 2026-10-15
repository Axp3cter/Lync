--!nocheck
-- Rows.encodeValue and Run.encode take the chunk's instances "collected beforehand", but nothing
-- enforces it: Leaves.instanceCode appends on first reference and each index is written as wide
-- as the list is at that moment, so an encode without Run.collect writes indices of growing width
-- that the decoder (which knows the final count) reads differently. Run: lune run p11_encode_without_collect.luau
local P = require("./prelude")
local Bits, Run, Rows = P.Bits, P.Run, P.Rows
local t = P.Lync.types

local codec = P.plan(P.Lync, { a = t.instance(), b = t.instance(), c = t.instance() })
local p, q, r = Instance.new("Part"), Instance.new("Model"), Instance.new("Folder")
local value = { a = p, b = q, c = r }

local instances = { list = {}, index = {} }
local w = Bits.writer()
Rows.encodeValue(w, codec, value, instances, "p.e:fire") -- no Run.collect first: no error
local bytes = Bits.finish(w)
print(string.format("encoded %d bits, list of %d, no error raised", w.bit, #instances.list))

local out = {}
local reader = Bits.reader(bytes)
local rule = Run.decode(reader, codec, 1, instances.list, out)
print(string.format("decode: rule %d, meets %s", rule, tostring(Bits.meets(reader))))
if rule == 0 and out[1] then
	print(string.format("  a = %s, b = %s, c = %s (sent Part, Model, Folder)", tostring(out[1].a and out[1].a.ClassName), tostring(out[1].b and out[1].b.ClassName), tostring(out[1].c and out[1].c.ClassName)))
end
