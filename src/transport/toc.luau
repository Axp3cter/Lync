--!strict

--[=[
	Toc

	A frame's table of contents (v5.md §4.1): one or more lists of segments, each a namespace
	index and how many chunks of the list's kind follow for it.

	The lists a frame has depend on its kind: a downstream reliable frame has state, run and
	remove lists; every other frame has one. The chunks follow the toc in toc order.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../wire/bits")
local Ints = require("../wire/ints")

-- Module ------------------------------------------------------------------------------------------

local Toc = {}

-- Types -------------------------------------------------------------------------------------------

--[=[
	One segment of a toc list.

	@field ns    the namespace index; 0 is control
	@field count how many chunks of the list's kind it holds, at least 1
]=]
export type Segment = {
	ns: number,
	count: number,
}

-- Constants ---------------------------------------------------------------------------------------

--- How many lists a downstream reliable frame's toc has: state, run and remove.
const RELIABLE_LIST_COUNT = 3

--- The run list's place among a downstream reliable frame's lists.
const RUN_LIST = 2

-- Private -----------------------------------------------------------------------------------------

-- Whether a list's segments must be in ascending namespace order (v5.md §4.1): the state and
-- remove lists of a downstream reliable frame.
local function isAscending(listCount: number, list: number): boolean
	return listCount == RELIABLE_LIST_COUNT and list ~= RUN_LIST
end

local function readList(r: Bits.Reader, ascending: boolean, segments: { Segment }): number
	local segmentCount, countRule = Ints.readEg(r, 0)
	if segmentCount == nil then
		return countRule
	end

	local previousNs = -1
	for i = 1, segmentCount do
		local ns, nsRule = Ints.readEg(r, 0)
		if ns == nil then
			return nsRule
		end

		local countLessOne, chunkRule = Ints.readEg(r, 0)
		if countLessOne == nil then
			return chunkRule
		end

		if ns == previousNs or (ascending and ns < previousNs) then
			return 6
		end
		previousNs = ns

		local segment = segments[i]
		if segment == nil then
			segment = { ns = ns, count = countLessOne + 1 }
			segments[i] = segment
		else
			segment.ns = ns
			segment.count = countLessOne + 1
		end
	end

	for i = #segments, segmentCount + 1, -1 do
		segments[i] = nil
	end

	return 0
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Reads a toc, checking rule 6's toc conditions: no two adjacent segments of one namespace, and
	state and remove segments in ascending namespace order.

	@param  r         the reader
	@param  listCount how many lists the frame kind has: 3 for a downstream reliable frame, else 1
	@param  out       where the lists are stored, at 1 to `listCount`; tables already there are
	                  reused, so a reader that keeps `out` allocates only for its largest toc
	@return 0, or the v5.md §4.8 rule that refuses the toc
]=]
function Toc.read(r: Bits.Reader, listCount: number, out: { { Segment } }): number
	for list = 1, listCount do
		local segments = out[list]
		if segments == nil then
			segments = {}
			out[list] = segments
		end

		local rule = readList(r, isAscending(listCount, list), segments)
		if rule ~= 0 then
			return rule
		end
	end

	return 0
end

--[=[
	Writes a toc.

	@param w     the writer
	@param lists the lists the frame kind has, in v5.md §4.1 order, each in the order its chunks
	             follow
]=]
function Toc.write(w: Bits.Writer, lists: { { Segment } })
	for _, segments in lists do
		Ints.writeEg(w, #segments, 0)
		for _, segment in segments do
			Ints.writeEg(w, segment.ns, 0)
			Ints.writeEg(w, segment.count - 1, 0)
		end
	end
end

return table.freeze(Toc)
