--!strict

--[=[
	control.spec

	Control chunks (v5.md §4.6): every type's rows round-trip, only the first `WELCOME` carries
	`First`, out-of-range fields are rules 2 and 3, a chunk cut short is rule 4, and a chunk's
	count is charged to the decode element budget (rule 10).
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../../src/wire/bits")
local Check = require("../support/check")
local Control = require("../../src/transport/control")
local Ints = require("../../src/wire/ints")
local Prop = require("../support/prop")

-- Constants ---------------------------------------------------------------------------------------

const U32 = 2 ^ 32 - 1

-- Private -----------------------------------------------------------------------------------------

-- A random integer in [0, max], for ranges past `math.random`'s 32 bits.
local function integerUpTo(max: number): number
	return math.floor(math.random() * (max + 1))
end

local function randomName(): string
	local bytes = {}
	for i = 1, math.random(1, 64) do
		bytes[i] = string.char(math.random(0, 255))
	end

	return table.concat(bytes)
end

local function randomFirst(): Control.First
	return {
		epoch = (math.random() - 0.5) * 2 ^ math.random(0, 60),
		stateRate = math.random(10, 60),
		keyLow = integerUpTo(U32),
		keyHigh = integerUpTo(U32),
		cover = math.random(0, 16_384),
		permutationSeed = integerUpTo(U32),
		probeOneIn = math.random(0, 255),
		probeMaxPerSecond = math.random(0, 63),
		beacon = math.random(0, 15),
	}
end

local function randomRow(kind: number, isFirstWelcome: boolean): any
	if kind == Control.HELLO then
		return {
			version = math.random(0, 255),
			seed = integerUpTo(U32),
			hashLow = integerUpTo(U32),
			hashHigh = integerUpTo(U32),
			name = randomName(),
		}
	elseif kind == Control.WELCOME then
		return {
			index = 1 + integerUpTo(2 ^ 40 - 1),
			first = if isFirstWelcome then randomFirst() else nil,
		}
	elseif kind == Control.REKEY then
		return { keyLow = integerUpTo(U32), keyHigh = integerUpTo(U32) }
	elseif kind == Control.REPORT then
		return {
			probes = integerUpTo(2 ^ 50),
			identitySucceeded = math.random(0, 9),
			sourceUnlisted = 0,
			refusedFrames = math.random(0, 2 ^ 20),
		}
	elseif kind == Control.BEACON then
		return math.random(0, 0xffff)
	elseif kind == Control.RATE then
		return { epoch = (math.random() - 0.5) * 2 ^ 40, stateRate = math.random(10, 60) }
	end

	return true
end

local function written(kind: number, rows: { any }): buffer
	local w = Bits.writer()
	Control.write(w, kind, rows)

	return Bits.finish(w)
end

-- The rule of a chunk whose header and first fields are written by `build`.
local function ruleOf(build: (w: Bits.Writer) -> (), firstWelcome: boolean?): number
	local w = Bits.writer()
	build(w)
	Bits.write(w, 32, 0)
	local _, rule = Control.read(Bits.reader(Bits.finish(w)), firstWelcome == true, {})

	return rule
end

local function writeHeader(w: Bits.Writer, kind: number)
	Bits.write(w, 3, kind)
	Ints.writeEg(w, 0, 0)
end

local function writeF64(w: Bits.Writer, value: number)
	local bytes = buffer.create(8)
	buffer.writef64(bytes, 0, value)
	Bits.write(w, 32, buffer.readu32(bytes, 0))
	Bits.write(w, 32, buffer.readu32(bytes, 4))
end

-- Writes a first `WELCOME` up to its `tag.cover`.
local function writeFirstWelcome(w: Bits.Writer, stateRate: number, cover: number)
	writeHeader(w, Control.WELCOME)
	Ints.writeEg(w, 1, 0)
	writeF64(w, 1000.5)
	Bits.write(w, 6, stateRate)
	Bits.write(w, 32, 0)
	Bits.write(w, 32, 0)
	Bits.write(w, 15, cover)
	Bits.write(w, 50, 0)
end

local function writeHelloLength(w: Bits.Writer, nameBytes: number)
	writeHeader(w, Control.HELLO)
	Bits.write(w, 8, 1)
	Bits.write(w, 32, 0)
	Bits.write(w, 32, 0)
	Bits.write(w, 32, 0)
	Bits.write(w, 7, nameBytes)
	Bits.writeTail(w, string.rep("n", nameBytes))
end

-- Tests -------------------------------------------------------------------------------------------

return {
	["every control type's rows round-trip"] = function()
		Prop.check("control rows", function()
			local kind = math.random(0, 7)
			local firstWelcome = math.random() < 0.5
			local rows = {}
			for i = 1, math.random(1, 4) do
				rows[i] = randomRow(kind, firstWelcome and i == 1)
			end
			return { kind = kind, firstWelcome = firstWelcome, rows = rows }
		end, function(case: { kind: number, firstWelcome: boolean, rows: { any } })
			local w = Bits.writer()
			Control.write(w, case.kind, case.rows)
			local r = Bits.reader(Bits.finish(w))
			local out = { "stale", "stale", "stale", "stale", "stale" }
			local kind, rule = Control.read(r, case.firstWelcome, out)
			Check.expectEqual({ kind, rule }, { case.kind, 0 }, "read")
			Check.expectEqual(out, case.rows, "rows")
			Check.expect(Bits.meets(r), "bits and tail must meet")
		end)
	end,

	["only the first WELCOME row of the connection carries First"] = function()
		local rows = { { index = 1, first = randomFirst() }, { index = 2 }, { index = 3 } }
		local out = {}
		local kind, rule = Control.read(Bits.reader(written(Control.WELCOME, rows)), true, out)
		Check.expectEqual({ kind, rule }, { Control.WELCOME, 0 }, "read")
		Check.expectEqual(out, rows, "rows")

		local later = { { index = 4 }, { index = 5 } }
		Control.read(Bits.reader(written(Control.WELCOME, later)), false, out)
		Check.expectEqual(out, later, "later rows")
	end,

	["a HELLO name is 1 to 64 bytes: 0 is rule 3, past 64 is rule 2"] = function()
		for _, case in { { 0, 3 }, { 1, 0 }, { 64, 0 }, { 65, 2 }, { 127, 2 } } do
			local nameBytes, rule = case[1], case[2]
			Check.expectEqual(
				ruleOf(function(w)
					writeHelloLength(w, nameBytes)
				end),
				rule,
				`{nameBytes} bytes`
			)
		end
	end,

	["a HELLO name overlapping its bits is rule 4"] = function()
		local bytes = written(Control.HELLO, { randomRow(Control.HELLO, false) })
		local cut = buffer.create(buffer.len(bytes) - 1)
		buffer.copy(cut, 0, bytes, 0, buffer.len(cut))
		local _, rule = Control.read(Bits.reader(cut), false, {})
		Check.expectEqual(rule, 4, "rule")
	end,

	["stateRate outside 10 to 60 is rule 3 in WELCOME and RATE"] = function()
		for _, case in { { 0, 3 }, { 9, 3 }, { 10, 0 }, { 60, 0 }, { 61, 3 }, { 63, 3 } } do
			local stateRate, rule = case[1], case[2]
			Check.expectEqual(
				ruleOf(function(w)
					writeFirstWelcome(w, stateRate, 1024)
				end, true),
				rule,
				`WELCOME at {stateRate}`
			)
			Check.expectEqual(
				ruleOf(function(w)
					writeHeader(w, Control.RATE)
					writeF64(w, 1000.5)
					Bits.write(w, 6, stateRate)
				end),
				rule,
				`RATE at {stateRate}`
			)
		end
	end,

	["tag.cover past 16,384 is rule 3"] = function()
		for _, case in { { 0, 0 }, { 16_384, 0 }, { 16_385, 3 }, { 32_767, 3 } } do
			local cover, rule = case[1], case[2]
			Check.expectEqual(
				ruleOf(function(w)
					writeFirstWelcome(w, 20, cover)
				end, true),
				rule,
				`cover {cover}`
			)
		end
	end,

	["a NaN or infinite epoch is rule 3"] = function()
		for _, epoch in { 0 / 0, math.huge, -math.huge } do
			Check.expectEqual(
				ruleOf(function(w)
					writeHeader(w, Control.RATE)
					writeF64(w, epoch)
					Bits.write(w, 6, 20)
				end),
				3,
				`RATE epoch {epoch}`
			)
		end
	end,

	["namespace index 0 is rule 3"] = function()
		Check.expectEqual(
			ruleOf(function(w)
				writeHeader(w, Control.WELCOME)
				Ints.writeEg(w, 0, 0)
			end),
			3,
			"index 0"
		)
	end,

	["a chunk cut short is rule 4"] = function()
		for kind = 0, 7 do
			local bytes = written(kind, { randomRow(kind, true) })
			for stop = 0, buffer.len(bytes) - 1 do
				local _, rule = Control.read(Bits.reader(bytes, 0, stop), true, {})
				Check.expectEqual(rule, 4, `type {kind}, {stop} bytes`)
			end
		end
	end,

	["a chunk's count is charged to the element budget"] = function()
		local bytes = written(Control.MISMATCH, { true, true, true })
		local short = Bits.reader(bytes, nil, nil, 2)
		Check.expectEqual(select(2, Control.read(short, false, {})), 10, "budget 2")
		local enough = Bits.reader(bytes, nil, nil, 3)
		local out = {}
		Check.expectEqual({ Control.read(enough, false, out) }, { Control.MISMATCH, 0 }, "budget 3")
		Check.expectEqual({ enough.budget, #out }, { 0, 3 }, "charged")
	end,

	["the type numbers are v5.md §4.6's"] = function()
		Check.expectEqual({
			Control.HELLO,
			Control.WELCOME,
			Control.MISMATCH,
			Control.REKEY,
			Control.REKEY_ACK,
			Control.REPORT,
			Control.BEACON,
			Control.RATE,
		}, { 0, 1, 2, 3, 4, 5, 6, 7 }, "types")
	end,
}
