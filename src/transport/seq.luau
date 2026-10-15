--!strict

--[=[
	Seq

	Extends a 12-bit sequence number to the full counter it stands for (v5.md §4.4): the value
	nearest the newest one received in that sequence.

	Consecutive values are one peer's consecutive frames, so an extension is wrong only after
	2048 consecutive losses. Counters start at 0 and are never negative.
]=]

-- Module ------------------------------------------------------------------------------------------

local Seq = {}

-- Constants ---------------------------------------------------------------------------------------

const SEQ_RANGE = 4096

--- The furthest ahead of the newest value an extension reaches; behind, one less.
const MAX_AHEAD = 2048

-- Public ------------------------------------------------------------------------------------------

--[=[
	Returns the full value a 12-bit sequence number stands for.

	@param  newest the newest full value received in the sequence, -1 before the first
	@param  seq12  the received value, 0 to 4095
	@return the non-negative value with the low 12 bits `seq12` nearest `newest`, from 2047
	        behind it to 2048 ahead
]=]
function Seq.extend(newest: number, seq12: number): number
	local ahead = (seq12 - newest) % SEQ_RANGE
	if ahead > MAX_AHEAD then
		ahead -= SEQ_RANGE
	end

	local full = newest + ahead
	if full < 0 then
		return full + SEQ_RANGE
	end

	return full
end

return table.freeze(Seq)
