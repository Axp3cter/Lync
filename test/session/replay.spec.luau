--!strict

--[=[
	replay.spec

	The upstream replay window (v5.md §4.5): RFC 4303's results for in-order, reordered,
	duplicate and too-old sequences over a 64-frame bitmap, checked by cases and against a
	model that keeps every accepted seq.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Check = require("../support/check")
local Prop = require("../support/prop")
local Replay = require("../../src/session/replay")

-- Constants ---------------------------------------------------------------------------------------

const NEW = 0
const SEEN = 1
const OLD = 2

-- Private -----------------------------------------------------------------------------------------

-- Checks the status of `full`, then accepts it when it is new.
local function receive(w: Replay.Window, full: number, expected: number)
	Check.expectEqual(Replay.status(w, full), expected, `seq {full}`)
	if expected == NEW then
		Replay.accept(w, full)
	end
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["an empty window takes any seq as new"] = function()
		local w = Replay.new()
		Check.expectEqual(Replay.newest(w), -1, "newest")
		for _, full in { 0, 1, 63, 64, 4095, 2 ^ 40 } do
			Check.expectEqual(Replay.status(w, full), NEW, `seq {full}`)
		end
	end,

	["in-order seqs are new, then seen"] = function()
		local w = Replay.new()
		for full = 0, 200 do
			receive(w, full, NEW)
			Check.expectEqual(Replay.newest(w), full, "newest")
			Check.expectEqual(Replay.status(w, full), SEEN, `seq {full} again`)
		end
	end,

	["reordered seqs inside the window are new once"] = function()
		local w = Replay.new()
		receive(w, 100, NEW)
		for _, full in { 99, 90, 68, 67, 37, 70 } do
			receive(w, full, NEW)
			Check.expectEqual(Replay.newest(w), 100, "newest")
		end
		for _, full in { 99, 90, 68, 67, 37, 70, 100 } do
			receive(w, full, SEEN)
		end
		receive(w, 36, OLD)
		receive(w, 0, OLD)
	end,

	["sliding keeps what is still inside the window"] = function()
		local w = Replay.new()
		receive(w, 10, NEW)
		receive(w, 5, NEW)
		receive(w, 40, NEW)
		receive(w, 68, NEW)
		receive(w, 5, SEEN)
		receive(w, 6, NEW)
		receive(w, 69, NEW)
		receive(w, 5, OLD)
		receive(w, 6, SEEN)
		receive(w, 10, SEEN)
		receive(w, 40, SEEN)
		receive(w, 11, NEW)
		receive(w, 1000, NEW)
		for _, full in { 10, 40, 69, 936 } do
			receive(w, full, OLD)
		end
		receive(w, 937, NEW)
		receive(w, 999, NEW)
		receive(w, 1000, SEEN)
	end,

	["the window matches a model that keeps every accepted seq"] = function()
		Prop.check("replay", function(size: number)
			local seqs = {}
			local newest = math.random(0, 2 ^ 20)
			for i = 1, 20 * size do
				newest += if math.random() < 0.7
					then math.random(1, 3)
					elseif math.random() < 0.5 then math.random(1, 100)
					else 0
				seqs[i] = math.max(0, newest - math.random(0, 80))
			end
			return seqs
		end, function(seqs: { number })
			local w = Replay.new()
			local accepted = {}
			local newest = -1
			for _, full in seqs do
				local expected = if full > newest
					then NEW
					elseif newest - full >= 64 then OLD
					elseif accepted[full] then SEEN
					else NEW
				receive(w, full, expected)
				if expected == NEW then
					accepted[full] = true
					newest = math.max(newest, full)
				end
				Check.expectEqual(Replay.newest(w), newest, "newest")
			end
		end)
	end,
}
