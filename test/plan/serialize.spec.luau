--!strict

--[=[
	serialize.spec

	The canonical serialization and hash of v5.md §4.7: golden vector G6 (§4.10), resolved
	defaults, and codec parameters.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Check = require("../support/check")
local Lync = require("../../src")

-- Constants ---------------------------------------------------------------------------------------

local t = Lync.types

-- Private -----------------------------------------------------------------------------------------

local function hashBytesOf(low: number, high: number): buffer
	local bytes = buffer.create(8)
	buffer.writeu32(bytes, 0, low)
	buffer.writeu32(bytes, 4, high)

	return bytes
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["G6: serialization and hash"] = function()
		local ir = Lync.schema("arena", {
			chat = Lync.event({ from = "client", data = t.string(200) }),
		}).ir

		Check.expectBytes(
			ir.serialization,
			"01 05 00 61 72 65 6e 61 01 00 04 00 63 68 61 74 01 01 01 01 08 00 00 00 00 00 00 69 40"
				.. " 00 00 00 00 00 00 00 00"
		)
		Check.expectBytes(hashBytesOf(ir.hashLow, ir.hashHigh), "ab 86 8b 15 cd 9c 16 40")
	end,

	["a request writes its resolved timeout"] = function()
		local ir = Lync.schema("s", {
			q = Lync.request({ from = "server" }),
		}).ir

		Check.expectBytes(
			ir.serialization,
			"01 01 00 73 01 00 01 00 71 02 02 01 00 00 00 00 00 01 00 00 00 00 00 00 24 40 00 00 00"
		)
	end,

	["a collection writes its resolved maxRecords and priority"] = function()
		local ir = Lync.schema("s", {
			c = Lync.collection({}),
		}).ir

		-- maxRecords 1024 is 0x4090000000000000; priority 1 is 0x3ff0000000000000.
		Check.expectBytes(
			ir.serialization,
			"01 01 00 73 01 00 01 00 63 03 02 01 00 00 00 00 00 00"
				.. " 01 00 00 00 00 00 00 90 40 01 00 00 00 00 00 00 f0 3f 00"
		)
	end,

	["a limit writes perSecond and its resolved burst"] = function()
		local ir = Lync.schema("s", {
			e = Lync.event({ from = "client", limit = { perSecond = 2.5 } }),
		}).ir

		-- perSecond 2.5 is 0x4004000000000000; burst ceil(2.5) = 3 is 0x4008000000000000.
		Check.expectBytes(
			ir.serialization,
			"01 01 00 73 01 00 01 00 65 01 01 01 00 00 00"
				.. " 01 00 00 00 00 00 00 04 40 01 00 00 00 00 00 00 08 40 00 00 00 00"
		)
	end,

	["codec parameters, records in name order, and -0 written as 0"] = function()
		local ir = Lync.schema("s", {
			v = Lync.event({
				from = "server",
				lane = "unreliable",
				data = {
					e = t.int(-0, 1),
					d = t.union({ v = {} }),
					c = t.instance(),
					b = t.enum({ "x" }),
					a = t.angle(0.5),
				},
			}),
		}).ir

		Check.expectBytes(
			ir.serialization,
			table.concat({
				"01 01 00 73 01 00 01 00 76 01 02 02",
				"01 17 05 00",
				"01 00 61 07 00 00 00 00 00 00 e0 3f 00",
				"01 00 62 10 01 00 01 00 78 00",
				"01 00 63 12 00 00 00",
				"01 00 64 16 01 00 01 00 76 17 00 00 00",
				"01 00 65 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 f0 3f 00",
				"00 00 00 00 00 00 00 00",
			}, " ")
		)
	end,

	["the hash depends on every option"] = function()
		local reliable = Lync.schema("s", {
			e = Lync.event({ from = "client", data = t.bool() }),
		}).ir
		local unreliable = Lync.schema("s", {
			e = Lync.event({ from = "client", lane = "unreliable", data = t.bool() }),
		}).ir

		Check.expect(reliable.hashLow ~= unreliable.hashLow, "the lane must change the hash")
	end,
}
