--!strict

--[=[
	header.spec

	Frame headers (v5.md §4.1): every header round-trips, writers keep only a field's low bits,
	and a header cut short is rule 4.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../../src/wire/bits")
local Check = require("../support/check")
local Header = require("../../src/transport/header")
local Prop = require("../support/prop")

-- Constants ---------------------------------------------------------------------------------------

const LANE_RELIABLE = 0
const LANE_UNRELIABLE = 1

-- Private -----------------------------------------------------------------------------------------

-- The header written alone, its bit count, and a reader over it.
local function written(write: (w: Bits.Writer) -> ()): (buffer, number)
	local w = Bits.writer()
	write(w)

	return Bits.finish(w), w.bit
end

-- A reader over the header's bytes less the last, which holds its last bit.
local function truncated(bytes: buffer): Bits.Reader
	return Bits.reader(bytes, 0, buffer.len(bytes) - 1)
end

local function randomAck(): Header.Ack?
	if math.random() < 0.5 then
		return nil
	end

	return { seq = math.random(0, 4095), received = math.random(0, 0xffff) }
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["downstream reliable headers round-trip"] = function()
		Prop.check("down reliable", function()
			return { math.random(0, 2), math.random(0, 2 ^ 20) }
		end, function(case: { number })
			local mode, tick = case[1], case[2]
			local bytes, bitCount = written(function(w)
				Header.writeDownReliable(w, mode, tick)
			end)
			Check.expectEqual(bitCount, ({ 1, 2, 18 })[mode + 1], "bits")

			local r = Bits.reader(bytes)
			local readMode, readTick, rule = Header.readDownReliable(r)
			local expectedTick = if mode == 2 then tick % 0x1_0000 else 0
			Check.expectEqual({ readMode, readTick, rule }, { mode, expectedTick, 0 }, "read")
			Check.expectEqual(r.bit, bitCount, "consumed")

			local _, _, cutRule = Header.readDownReliable(truncated(bytes))
			Check.expectEqual(cutRule, 4, "cut short")
		end)
	end,

	["downstream unreliable headers round-trip"] = function()
		Prop.check("down unreliable", function()
			return { math.random() < 0.5, math.random(0, 2 ^ 20), math.random(0, 255) }
		end, function(case: { any })
			local isState, seq, tick8 = case[1], case[2], case[3]
			local bytes, bitCount = written(function(w)
				Header.writeDownUnreliable(w, if isState then seq else nil, tick8)
			end)
			Check.expectEqual(bitCount, if isState then 21 else 9, "bits")

			local readState, readSeq, readTick8, rule =
				Header.readDownUnreliable(Bits.reader(bytes))
			local expectedSeq = if isState then seq % 4096 else 0
			Check.expectEqual(
				{ readState, readSeq, readTick8, rule },
				{ isState, expectedSeq, tick8, 0 },
				"read"
			)

			local _, _, _, cutRule = Header.readDownUnreliable(truncated(bytes))
			Check.expectEqual(cutRule, 4, "cut short")
		end)
	end,

	["upstream headers round-trip on both lanes"] = function()
		Prop.check("up", function()
			return { math.random(0, 1), math.random(0, 2 ^ 30), randomAck() }
		end, function(case: { any })
			local lane, seq, ack = case[1], case[2], case[3]
			local isUnreliable = lane == LANE_UNRELIABLE
			local bytes, bitCount = written(function(w)
				Header.writeUp(w, lane, if isUnreliable then seq else nil, ack)
			end)
			local ackBits = if ack == nil then 1 else 29
			Check.expectEqual(bitCount, ackBits + if isUnreliable then 12 else 0, "bits")

			local readSeq, readAck, rule = Header.readUp(Bits.reader(bytes), lane)
			Check.expectEqual(rule, 0, "rule")
			Check.expectEqual(readSeq, if isUnreliable then seq % 4096 else nil, "seq")
			Check.expectEqual(readAck, ack, "ack")

			local cutSeq, cutAck, cutRule = Header.readUp(truncated(bytes), lane)
			Check.expectEqual({ cutSeq, cutAck, cutRule }, { nil, nil, 4 }, "cut short")
		end)
	end,

	["an ack keeps the low 12 bits of its seq"] = function()
		local bytes = written(function(w)
			Header.writeUp(w, LANE_RELIABLE, nil, { seq = 4096 + 7, received = 1 })
		end)
		local _, ack = Header.readUp(Bits.reader(bytes), LANE_RELIABLE)
		Check.expectEqual(ack, { seq = 7, received = 1 }, "ack")
	end,

	["an empty frame has no header"] = function()
		local empty = buffer.create(0)
		Check.expectEqual(
			select(3, Header.readDownReliable(Bits.reader(empty))),
			4,
			"down reliable"
		)
		Check.expectEqual(
			select(4, Header.readDownUnreliable(Bits.reader(empty))),
			4,
			"down unreliable"
		)
		Check.expectEqual(select(3, Header.readUp(Bits.reader(empty), LANE_UNRELIABLE)), 4, "up")
	end,
}
