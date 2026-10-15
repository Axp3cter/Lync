--!strict

--[=[
	Control

	Control chunks (v5.md §4.6): a run chunk of namespace 0 holding consecutive control messages
	of one type, `type:u3 count-1:EG0` and then each message's fields.

	A row is a message's fields: `Hello`, `Welcome`, `Rekey`, `Report` and `Rate` records, the
	`BEACON` time as a number, and `true` for `MISMATCH` and `REKEY-ACK`, which have no fields.
	Names go to the tail. Which direction a type may travel, and when, is the session's to check
	(rule 7).
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../wire/bits")
local Ints = require("../wire/ints")
local Leaves = require("../codec/leaves")

-- Module ------------------------------------------------------------------------------------------

local Control = {}

-- Types -------------------------------------------------------------------------------------------

--[=[
	A client's `HELLO` for one namespace.

	@field version  the protocol version
	@field seed     the build seed
	@field hashLow  the schema hash's low u32
	@field hashHigh the schema hash's high u32
	@field name     the namespace's name, 1 to 64 bytes
]=]
export type Hello = {
	version: number,
	seed: number,
	hashLow: number,
	hashHigh: number,
	name: string,
}

--[=[
	What a connection's first `WELCOME` carries beyond the namespace index.

	@field epoch             the state tick epoch, in `GetServerTimeNow()` seconds
	@field stateRate         state ticks per second, 10 to 60
	@field keyLow            the tag key's low u32
	@field keyHigh           the tag key's high u32
	@field cover             `tag.cover`: how many frame bytes the tag covers, 0 to 16,384
	@field permutationSeed   the id permutation seed; 0 is the identity
	@field probeOneIn        `callerProbe.oneIn`, 0 until milestone 5
	@field probeMaxPerSecond `callerProbe.maxPerSecond`, 0 until milestone 5
	@field beacon            `clock.beacon` in tenths of a second, 0 until milestone 5
]=]
export type First = {
	epoch: number,
	stateRate: number,
	keyLow: number,
	keyHigh: number,
	cover: number,
	permutationSeed: number,
	probeOneIn: number,
	probeMaxPerSecond: number,
	beacon: number,
}

--[=[
	The server's `WELCOME` for one namespace.

	@field index the namespace's server-wide index, from 1
	@field first the connection settings, in the connection's first `WELCOME` only
]=]
export type Welcome = {
	index: number,
	first: First?,
}

--[=[
	A new tag key in `REKEY`.

	@field keyLow  the key's low u32
	@field keyHigh the key's high u32
]=]
export type Rekey = {
	keyLow: number,
	keyHigh: number,
}

--[=[
	A new state tick rate in `RATE`.

	@field epoch     the state tick epoch, in `GetServerTimeNow()` seconds
	@field stateRate state ticks per second, 10 to 60
]=]
export type Rate = {
	epoch: number,
	stateRate: number,
}

--[=[
	A client's integrity `REPORT` (milestone 5).

	@field probes            caller probes run
	@field identitySucceeded probes whose identity check succeeded
	@field sourceUnlisted    probes from an unlisted source
	@field refusedFrames     frames the client refused
]=]
export type Report = {
	probes: number,
	identitySucceeded: number,
	sourceUnlisted: number,
	refusedFrames: number,
}

-- Constants ---------------------------------------------------------------------------------------

const HELLO = 0
const WELCOME = 1
const MISMATCH = 2
const REKEY = 3
const REKEY_ACK = 4
const REPORT = 5
const BEACON = 6
const RATE = 7

const TYPE_BITS = 3
const VERSION_BITS = 8
const U32_BITS = 32
const NAME_LENGTH_BITS = 7
const STATE_RATE_BITS = 6
const COVER_BITS = 15
const PROBE_ONE_IN_BITS = 8
const PROBE_MAX_PER_SECOND_BITS = 6
const BEACON_INTERVAL_BITS = 4
const BEACON_TIME_BITS = 16

const MIN_NAME_BYTES = 1
const MAX_NAME_BYTES = 64
const MIN_STATE_RATE = 10
const MAX_STATE_RATE = 60
const MAX_COVER = 16_384

const F64_SCRATCH = buffer.create(8)

-- Private -----------------------------------------------------------------------------------------

local function writeF64(w: Bits.Writer, value: number)
	buffer.writef64(F64_SCRATCH, 0, value)
	Bits.write(w, U32_BITS, buffer.readu32(F64_SCRATCH, 0))
	Bits.write(w, U32_BITS, buffer.readu32(F64_SCRATCH, 4))
end

-- An epoch's f64, or nil and the rule: 4 when bits run out, 3 when it is NaN or infinite.
local function readEpoch(r: Bits.Reader): (number?, number)
	local low = Bits.read(r, U32_BITS)
	local high = Bits.read(r, U32_BITS)
	if low == nil or high == nil then
		return nil, 4
	end

	local epoch = Leaves.f64Of(low, high)
	if epoch == nil then
		return nil, 3
	end

	return epoch, 0
end

local function readStateRate(r: Bits.Reader): (number?, number)
	local stateRate = Bits.read(r, STATE_RATE_BITS)
	if stateRate == nil then
		return nil, 4
	end

	if stateRate < MIN_STATE_RATE or stateRate > MAX_STATE_RATE then
		return nil, 3
	end

	return stateRate, 0
end

local function writeHello(w: Bits.Writer, hello: Hello)
	Bits.write(w, VERSION_BITS, hello.version)
	Bits.write(w, U32_BITS, hello.seed)
	Bits.write(w, U32_BITS, hello.hashLow)
	Bits.write(w, U32_BITS, hello.hashHigh)
	Bits.write(w, NAME_LENGTH_BITS, #hello.name)
	Bits.writeTail(w, hello.name)
end

local function readHello(r: Bits.Reader): (Hello?, number)
	local version = Bits.read(r, VERSION_BITS)
	local seed = Bits.read(r, U32_BITS)
	local hashLow = Bits.read(r, U32_BITS)
	local hashHigh = Bits.read(r, U32_BITS)
	local nameBytes = Bits.read(r, NAME_LENGTH_BITS)
	if version == nil or seed == nil or hashLow == nil or hashHigh == nil or nameBytes == nil then
		return nil, 4
	end

	if nameBytes > MAX_NAME_BYTES then
		return nil, 2
	end

	if nameBytes < MIN_NAME_BYTES then
		return nil, 3
	end

	local name = Bits.readTail(r, nameBytes, false)
	if name == nil then
		return nil, 4
	end

	return {
		version = version,
		seed = seed,
		hashLow = hashLow,
		hashHigh = hashHigh,
		name = name :: string,
	},
		0
end

local function writeWelcome(w: Bits.Writer, welcome: Welcome)
	Ints.writeEg(w, welcome.index, 0)
	local first = welcome.first
	if first == nil then
		return
	end

	writeF64(w, first.epoch)
	Bits.write(w, STATE_RATE_BITS, first.stateRate)
	Bits.write(w, U32_BITS, first.keyLow)
	Bits.write(w, U32_BITS, first.keyHigh)
	Bits.write(w, COVER_BITS, first.cover)
	Bits.write(w, U32_BITS, first.permutationSeed)
	Bits.write(w, PROBE_ONE_IN_BITS, first.probeOneIn)
	Bits.write(w, PROBE_MAX_PER_SECOND_BITS, first.probeMaxPerSecond)
	Bits.write(w, BEACON_INTERVAL_BITS, first.beacon)
end

local function readFirst(r: Bits.Reader): (First?, number)
	local epoch, epochRule = readEpoch(r)
	if epoch == nil then
		return nil, epochRule
	end

	local stateRate, stateRateRule = readStateRate(r)
	if stateRate == nil then
		return nil, stateRateRule
	end

	local keyLow = Bits.read(r, U32_BITS)
	local keyHigh = Bits.read(r, U32_BITS)
	local cover = Bits.read(r, COVER_BITS)
	local permutationSeed = Bits.read(r, U32_BITS)
	local probeOneIn = Bits.read(r, PROBE_ONE_IN_BITS)
	local probeMaxPerSecond = Bits.read(r, PROBE_MAX_PER_SECOND_BITS)
	local beacon = Bits.read(r, BEACON_INTERVAL_BITS)
	if
		keyLow == nil
		or keyHigh == nil
		or cover == nil
		or permutationSeed == nil
		or probeOneIn == nil
		or probeMaxPerSecond == nil
		or beacon == nil
	then
		return nil, 4
	end

	if cover > MAX_COVER then
		return nil, 3
	end

	return {
		epoch = epoch,
		stateRate = stateRate,
		keyLow = keyLow,
		keyHigh = keyHigh,
		cover = cover,
		permutationSeed = permutationSeed,
		probeOneIn = probeOneIn,
		probeMaxPerSecond = probeMaxPerSecond,
		beacon = beacon,
	},
		0
end

local function readWelcome(r: Bits.Reader, isFirst: boolean): (Welcome?, number)
	local index, indexRule = Ints.readEg(r, 0)
	if index == nil then
		return nil, indexRule
	end

	-- Namespace 0 is control; the server numbers namespaces from 1 (v5.md §4.6).
	if index == 0 then
		return nil, 3
	end

	if not isFirst then
		return { index = index }, 0
	end

	local first, firstRule = readFirst(r)
	if first == nil then
		return nil, firstRule
	end

	return { index = index, first = first }, 0
end

local function writeRekey(w: Bits.Writer, rekey: Rekey)
	Bits.write(w, U32_BITS, rekey.keyLow)
	Bits.write(w, U32_BITS, rekey.keyHigh)
end

local function readRekey(r: Bits.Reader): (Rekey?, number)
	local keyLow = Bits.read(r, U32_BITS)
	local keyHigh = Bits.read(r, U32_BITS)
	if keyLow == nil or keyHigh == nil then
		return nil, 4
	end

	return { keyLow = keyLow, keyHigh = keyHigh }, 0
end

local function writeReport(w: Bits.Writer, report: Report)
	Ints.writeEg(w, report.probes, 0)
	Ints.writeEg(w, report.identitySucceeded, 0)
	Ints.writeEg(w, report.sourceUnlisted, 0)
	Ints.writeEg(w, report.refusedFrames, 0)
end

local function readReport(r: Bits.Reader): (Report?, number)
	local probes, probesRule = Ints.readEg(r, 0)
	if probes == nil then
		return nil, probesRule
	end

	local identitySucceeded, identityRule = Ints.readEg(r, 0)
	if identitySucceeded == nil then
		return nil, identityRule
	end

	local sourceUnlisted, sourceRule = Ints.readEg(r, 0)
	if sourceUnlisted == nil then
		return nil, sourceRule
	end

	local refusedFrames, refusedRule = Ints.readEg(r, 0)
	if refusedFrames == nil then
		return nil, refusedRule
	end

	return {
		probes = probes,
		identitySucceeded = identitySucceeded,
		sourceUnlisted = sourceUnlisted,
		refusedFrames = refusedFrames,
	},
		0
end

local function writeRate(w: Bits.Writer, rate: Rate)
	writeF64(w, rate.epoch)
	Bits.write(w, STATE_RATE_BITS, rate.stateRate)
end

local function readRate(r: Bits.Reader): (Rate?, number)
	local epoch, epochRule = readEpoch(r)
	if epoch == nil then
		return nil, epochRule
	end

	local stateRate, stateRateRule = readStateRate(r)
	if stateRate == nil then
		return nil, stateRateRule
	end

	return { epoch = epoch, stateRate = stateRate }, 0
end

local function readBeacon(r: Bits.Reader): (number?, number)
	local time = Bits.read(r, BEACON_TIME_BITS)
	if time == nil then
		return nil, 4
	end

	return time, 0
end

local function writeRow(w: Bits.Writer, kind: number, row: any)
	if kind == HELLO then
		writeHello(w, row)
	elseif kind == WELCOME then
		writeWelcome(w, row)
	elseif kind == REKEY then
		writeRekey(w, row)
	elseif kind == REPORT then
		writeReport(w, row)
	elseif kind == BEACON then
		Bits.write(w, BEACON_TIME_BITS, row)
	elseif kind == RATE then
		writeRate(w, row)
	end
end

local function readRow(r: Bits.Reader, kind: number, isFirstWelcome: boolean): (any, number)
	if kind == HELLO then
		return readHello(r)
	elseif kind == WELCOME then
		return readWelcome(r, isFirstWelcome)
	elseif kind == REKEY then
		return readRekey(r)
	elseif kind == REPORT then
		return readReport(r)
	elseif kind == BEACON then
		return readBeacon(r)
	elseif kind == RATE then
		return readRate(r)
	end

	return true, 0
end

-- Public ------------------------------------------------------------------------------------------

Control.HELLO = HELLO
Control.WELCOME = WELCOME
Control.MISMATCH = MISMATCH
Control.REKEY = REKEY
Control.REKEY_ACK = REKEY_ACK
Control.REPORT = REPORT
Control.BEACON = BEACON
Control.RATE = RATE

--[=[
	Reads a control chunk, its header and every row.

	@param  r            the reader, at the chunk's first bit; its budget is charged for the
	                     chunk's count, as for a run (v5.md §4.8)
	@param  firstWelcome whether the connection's first `WELCOME` is still to come, so that a
	                     `WELCOME` chunk's first row carries `First`
	@param  out          where the rows are stored, at 1 to the chunk's count; cleared first
	@return the control type, 0 to 7, or nil on refusal
	@return 0, or the v5.md §4.8 rule that refuses the chunk
]=]
function Control.read(r: Bits.Reader, firstWelcome: boolean, out: { any }): (number?, number)
	table.clear(out)
	local kind = Bits.read(r, TYPE_BITS)
	if kind == nil then
		return nil, 4
	end

	local countLessOne, countRule = Ints.readEg(r, 0)
	if countLessOne == nil then
		return nil, countRule
	end

	local count = countLessOne + 1
	if not Bits.charge(r, count) then
		return nil, 10
	end

	for i = 1, count do
		local row, rule = readRow(r, kind, firstWelcome and i == 1)
		if rule ~= 0 then
			return nil, rule
		end
		out[i] = row
	end

	return kind, 0
end

--[=[
	Writes one control chunk.

	@param w    the writer
	@param kind the control type, 0 to 7
	@param rows the messages' fields, at least one; a chunk's first `WELCOME` row carries `first`
	            when it is the connection's first
]=]
function Control.write(w: Bits.Writer, kind: number, rows: { any })
	Bits.write(w, TYPE_BITS, kind)
	Ints.writeEg(w, #rows - 1, 0)
	for _, row in rows do
		writeRow(w, kind, row)
	end
end

return table.freeze(Control)
