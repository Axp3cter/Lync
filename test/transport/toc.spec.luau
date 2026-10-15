--!strict

--[=[
	toc.spec

	The segment toc (v5.md §4.1): canonical tocs round-trip; adjacent segments of one namespace,
	and state or remove segments out of ascending order, are rule 6; a toc cut short is rule 4
	and an EG code past z = 53 is rule 2.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../../src/wire/bits")
local Check = require("../support/check")
local Ints = require("../../src/wire/ints")
local Prop = require("../support/prop")
local Toc = require("../../src/transport/toc")

-- Private -----------------------------------------------------------------------------------------

-- A canonical list: no two adjacent segments of one namespace, ascending when `ascending`.
local function randomList(size: number, ascending: boolean): { Toc.Segment }
	local segments = {}
	local ns = math.random(0, 3)
	for i = 1, math.random(0, 1 + size // 10) do
		segments[i] = { ns = ns, count = if math.random() < 0.1 then 2 ^ 40 else math.random(1, 5) }
		ns = if ascending then ns + math.random(1, 4) else (ns + math.random(1, 6)) % 7
	end

	return segments
end

local function written(lists: { { Toc.Segment } }): buffer
	local w = Bits.writer()
	Toc.write(w, lists)

	return Bits.finish(w)
end

local function ruleOf(lists: { { Toc.Segment } }): number
	return Toc.read(Bits.reader(written(lists)), #lists, {})
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["canonical tocs round-trip with one list or three"] = function()
		Prop.check("toc", function(size: number)
			if math.random() < 0.5 then
				return { randomList(size, false) }
			end
			return { randomList(size, true), randomList(size, false), randomList(size, true) }
		end, function(lists: { { Toc.Segment } })
			local w = Bits.writer()
			Toc.write(w, lists)
			local r = Bits.reader(Bits.finish(w))
			local out = {}
			Check.expectEqual(Toc.read(r, #lists, out), 0, "rule")
			Check.expectEqual(out, lists, "lists")
			Check.expectEqual(r.bit, w.bit, "consumed")
		end)
	end,

	["adjacent segments of one namespace are rule 6 in every list"] = function()
		local repeated = { { ns = 2, count = 1 }, { ns = 2, count = 3 } }
		Check.expectEqual(ruleOf({ repeated }), 6, "one list")
		Check.expectEqual(ruleOf({ {}, repeated, {} }), 6, "run list")
		Check.expectEqual(ruleOf({ repeated, {}, {} }), 6, "state list")
		Check.expectEqual(ruleOf({ {}, {}, repeated }), 6, "remove list")
		Check.expectEqual(
			ruleOf({ { { ns = 2, count = 1 }, { ns = 1, count = 1 }, { ns = 2, count = 1 } } }),
			0,
			"not adjacent"
		)
	end,

	["state and remove segments out of ascending order are rule 6, runs are not"] = function()
		local descending = { { ns = 3, count = 1 }, { ns = 1, count = 1 } }
		Check.expectEqual(ruleOf({ descending, {}, {} }), 6, "state")
		Check.expectEqual(ruleOf({ {}, {}, descending }), 6, "remove")
		Check.expectEqual(ruleOf({ {}, descending, {} }), 0, "runs are in call order")
		Check.expectEqual(ruleOf({ descending }), 0, "a one-list toc")
	end,

	["a toc cut short is rule 4"] = function()
		local lists = { { { ns = 1, count = 2 } }, { { ns = 300, count = 9 } }, {} }
		local bytes = written(lists)
		for stop = 0, buffer.len(bytes) - 1 do
			Check.expectEqual(Toc.read(Bits.reader(bytes, 0, stop), 3, {}), 4, `{stop} bytes`)
		end
	end,

	["an EG code past z = 53 is rule 2"] = function()
		local w = Bits.writer()
		Ints.writeEg(w, 1, 0)
		Bits.write(w, 53, 0)
		Bits.write(w, 1, 0)
		Bits.write(w, 1, 1)
		Bits.write(w, 53, 0)
		Bits.write(w, 1, 0)
		Check.expectEqual(Toc.read(Bits.reader(Bits.finish(w)), 1, {}), 2, "namespace")
	end,

	["reading reuses the lists it is given and drops what it no longer needs"] = function()
		local out = {}
		Check.expectEqual(
			Toc.read(Bits.reader(written({ {}, randomList(80, false), {} })), 3, out),
			0,
			"first"
		)
		local runs = out[2]
		local short = { { { ns = 1, count = 1 } }, { { ns = 4, count = 2 } }, {} }
		Check.expectEqual(Toc.read(Bits.reader(written(short)), 3, out), 0, "second")
		Check.expectEqual(out, short, "lists")
		Check.expect(out[2] == runs, "the run list is the same table")
	end,

	["segment counts are EG-0 of count - 1"] = function()
		local w = Bits.writer()
		Ints.writeEg(w, 1, 0)
		Ints.writeEg(w, 5, 0)
		Ints.writeEg(w, 0, 0)
		local out = {}
		Check.expectEqual(Toc.read(Bits.reader(Bits.finish(w)), 1, out), 0, "rule")
		Check.expectEqual(out, { { { ns = 5, count = 1 } } }, "lists")
	end,
}
