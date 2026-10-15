--!strict

--[=[
	Header

	Frame headers (v5.md §4.1): the downstream reliable tick, the downstream unreliable frame kind
	with its seq and tick, and the upstream seq and ack.

	Writers take full counters and write their low bits: a tick as u16, a seq as u12. Readers
	return the fields as sent, for the caller to extend (§4.4), and a §4.8 rule: 4 when bits run
	out.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../wire/bits")
local Host = require("../host/host")

-- Module ------------------------------------------------------------------------------------------

local Header = {}

-- Types -------------------------------------------------------------------------------------------

--[=[
	The newest state frame a client received, and which of the 16 before it it received too.

	@field seq      the newest state-frame seq received
	@field received bit i set when state frame `seq - 1 - i` was received, 16 bits
]=]
export type Ack = {
	seq: number,
	received: number,
}

-- Constants ---------------------------------------------------------------------------------------

const MODE_UNCHANGED = 0
const MODE_NEXT = 1
const MODE_FULL = 2

const TICK_BITS = 16
const TICK_RANGE = 0x1_0000
const TICK8_BITS = 8
const SEQ_BITS = 12
const SEQ_RANGE = 4096
const RECEIVED_BITS = 16

const LANE_UNRELIABLE = 1

-- Private -----------------------------------------------------------------------------------------

local function writeAck(w: Bits.Writer, ack: Ack?)
	if ack == nil then
		Bits.write(w, 1, 0)
		return
	end

	Bits.write(w, 1, 1)
	Bits.write(w, SEQ_BITS, ack.seq % SEQ_RANGE)
	Bits.write(w, RECEIVED_BITS, ack.received)
end

local function readAck(r: Bits.Reader): (Ack?, number)
	local hasAck = Bits.read(r, 1)
	if hasAck == nil then
		return nil, 4
	end

	if hasAck == 0 then
		return nil, 0
	end

	local seq = Bits.read(r, SEQ_BITS)
	local received = Bits.read(r, RECEIVED_BITS)
	if seq == nil or received == nil then
		return nil, 4
	end

	return { seq = seq, received = received }, 0
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Reads a downstream reliable frame's tick header.

	@param  r the reader
	@return the mode: 0 unchanged, 1 plus one, 2 full; nil on refusal
	@return the tick's u16 when the mode is 2, else 0
	@return 0, or the rule that refuses the header
]=]
function Header.readDownReliable(r: Bits.Reader): (number?, number, number)
	local isChanged = Bits.read(r, 1)
	if isChanged == nil then
		return nil, 0, 4
	end

	if isChanged == 0 then
		return MODE_UNCHANGED, 0, 0
	end

	local isFull = Bits.read(r, 1)
	if isFull == nil then
		return nil, 0, 4
	end

	if isFull == 0 then
		return MODE_NEXT, 0, 0
	end

	local tick = Bits.read(r, TICK_BITS)
	if tick == nil then
		return nil, 0, 4
	end

	return MODE_FULL, tick, 0
end

--[=[
	Reads a downstream unreliable frame's header.

	@param  r the reader
	@return true for a state frame, false for an event frame, nil on refusal
	@return the state frame's u12 seq, else 0
	@return the low 8 bits of the state tick
	@return 0, or the rule that refuses the header
]=]
function Header.readDownUnreliable(r: Bits.Reader): (boolean?, number, number, number)
	local isState = Bits.read(r, 1)
	if isState == nil then
		return nil, 0, 0, 4
	end

	local seq = 0
	if isState == 1 then
		local stateSeq = Bits.read(r, SEQ_BITS)
		if stateSeq == nil then
			return nil, 0, 0, 4
		end
		seq = stateSeq
	end

	local tick8 = Bits.read(r, TICK8_BITS)
	if tick8 == nil then
		return nil, 0, 0, 4
	end

	return isState == 1, seq, tick8, 0
end

--[=[
	Reads an upstream frame's header.

	@param  r    the reader
	@param  lane the remote the frame came on
	@return the unreliable frame's u12 seq; nil on the reliable lane or on refusal
	@return the ack, or nil when it is `'0'` or on refusal
	@return 0, or the rule that refuses the header
]=]
function Header.readUp(r: Bits.Reader, lane: Host.Lane): (number?, Ack?, number)
	local seq: number? = nil
	if lane == LANE_UNRELIABLE then
		seq = Bits.read(r, SEQ_BITS)
		if seq == nil then
			return nil, nil, 4
		end
	end

	local ack, rule = readAck(r)
	if rule ~= 0 then
		return nil, nil, rule
	end

	return seq, ack, 0
end

--[=[
	Writes a downstream reliable frame's tick header, against the last reliable frame the client
	received.

	@param w    the writer
	@param mode 0 unchanged (`'0'`), 1 plus one (`'10'`), 2 full (`'11'` and a u16)
	@param tick the state tick T, written as its low 16 bits when the mode is 2
]=]
function Header.writeDownReliable(w: Bits.Writer, mode: number, tick: number)
	if mode == MODE_UNCHANGED then
		Bits.write(w, 1, 0)
	elseif mode == MODE_NEXT then
		Bits.write(w, 2, 0b01)
	else
		Bits.write(w, 2, 0b11)
		Bits.write(w, TICK_BITS, tick % TICK_RANGE)
	end
end

--[=[
	Writes a downstream unreliable frame's header.

	@param w     the writer
	@param seq   the player's state-frame counter for a state frame (`'1'`), nil for an event
	             frame (`'0'`)
	@param tick8 the low 8 bits of the state tick T
]=]
function Header.writeDownUnreliable(w: Bits.Writer, seq: number?, tick8: number)
	if seq == nil then
		Bits.write(w, 1, 0)
	else
		Bits.write(w, 1, 1)
		Bits.write(w, SEQ_BITS, seq % SEQ_RANGE)
	end
	Bits.write(w, TICK8_BITS, tick8)
end

--[=[
	Writes an upstream frame's header.

	@param w    the writer
	@param lane the remote the frame goes on
	@param seq  the client's unreliable-frame counter on the unreliable lane; nil on the reliable
	            lane
	@param ack  the newest state frame received, nil for `'0'`
]=]
function Header.writeUp(w: Bits.Writer, lane: Host.Lane, seq: number?, ack: Ack?)
	if lane == LANE_UNRELIABLE then
		Bits.write(w, SEQ_BITS, (seq :: number) % SEQ_RANGE)
	end
	writeAck(w, ack)
end

return table.freeze(Header)
