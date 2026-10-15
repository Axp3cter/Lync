--!nocheck
-- Rows.read, Columns.read and Leaves.{begin,end}Instances size a chunk's instance list with `#list`,
-- while the list is documented as "a missing instance is nil" (unreplicated instances arrive as nil,
-- v5.md §4.2, m1-plan §6.2). `#` of a table with holes is any border.
-- Run: lune run p4_instance_holes.luau
local P = require("./prelude")
local Bits, Run = P.Bits, P.Run
local t = P.Lync.types

local codec = P.plan(P.Lync, { a = t.instance(), b = t.instance(), c = t.instance() })
local p, q, r = Instance.new("Part"), Instance.new("Part"), Instance.new("Part")

local instances = { list = {}, index = {} }
local values = { { a = p, b = q, c = r } }
Run.collect(codec, values, 1, instances)
local w = Bits.writer()
Run.encode(w, codec, values, 1, instances, "p.e:fire")
local bytes = Bits.finish(w)

local function decodeWith(list, label)
	local out = {}
	local reader = Bits.reader(bytes)
	local rule = Run.decode(reader, codec, 1, list, out)
	print(string.format("%-44s #list = %d, rule %d, meets %s", label, #list, rule, tostring(Bits.meets(reader))))
end

decodeWith({ p, q, r }, "all three replicated")
decodeWith({ p, nil, r }, "q missing, list built by constructor")
local assigned = {}
assigned[1] = p
assigned[3] = r
decodeWith(assigned, "q missing, list built by assignment")
local trailing = {}
trailing[1] = p
trailing[2] = q
decodeWith(trailing, "r missing (trailing nil)")
