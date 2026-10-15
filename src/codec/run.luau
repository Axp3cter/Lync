--!strict

--[=[
	Run

	The payloads of a run of messages of one definition (v5.md §4.3): fewer than `Column.MIN_ROWS`
	messages are single rows one after another, more are one column block. The decoder knows the
	form from the count, so no flag is sent.

	A run's chunk header (`id`, `count - 1`, `instances`, §4.1) belongs to the transport. Its
	instance list must be known before the payloads are written, since indices are as wide as the
	list needs, so `Run.collect` lists them first.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Bits = require("../wire/bits")
local Column = require("../wire/column")
local Columns = require("./columns")
local Ir = require("../plan/ir")
local Leaves = require("./leaves")
local Rows = require("./rows")

-- Module ------------------------------------------------------------------------------------------

local Run = {}

-- State -------------------------------------------------------------------------------------------

--- Where `Run.collect` encodes the run to find its instances; the bits are discarded.
local scratch = Bits.writer()

-- Private -----------------------------------------------------------------------------------------

local function write(
	w: Bits.Writer,
	codec: Ir.Codec,
	values: { any },
	count: number,
	instances: Rows.Instances
): Rows.Refusal?
	if count >= Column.MIN_ROWS then
		return Columns.write(w, codec, values, 1, count, instances)
	end

	for i = 1, count do
		local refusal = Rows.write(w, codec, values[i], instances)
		if refusal ~= nil then
			return refusal
		end
	end

	return nil
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Lists a run's instances, each once, in the order the payloads reference them first.

	It encodes the run and discards the bits; a value the codec refuses ends the listing, and
	`Run.encode` then raises for it.

	@param codec  the messages' codec
	@param values the messages' values, at 1 to `count`
	@param count  how many messages
	@param into   the chunk's instances, extended
]=]
function Run.collect(codec: Ir.Codec, values: { any }, count: number, into: Rows.Instances)
	write(scratch, codec, values, count, into)
	Leaves.reset(scratch, 0, 0, 0)
end

--[=[
	Decodes a run's payloads, and checks the chunk's instance list (rule 9).

	@param  r         the reader, after the run's chunk header
	@param  codec     the messages' codec
	@param  count     how many messages, from the header
	@param  instances the chunk's instance list; a missing instance is nil
	@param  out       where the values are stored, at 1 to `count`
	@return 0, or the v5.md §4.8 rule that refuses the run
]=]
function Run.decode(
	r: Bits.Reader,
	codec: Ir.Codec,
	count: number,
	instances: { Instance? },
	out: { any }
): number
	local rule = Leaves.beginInstances(instances)
	if rule ~= 0 then
		return rule
	end

	if count >= Column.MIN_ROWS then
		rule = Columns.read(r, codec, count, instances, out)
	else
		for i = 1, count do
			local value, rowRule = Rows.read(r, codec, instances)
			if rowRule ~= 0 then
				rule = rowRule
				break
			end
			out[i] = value
		end
	end

	if rule ~= 0 then
		return rule
	end

	return Leaves.endInstances(instances)
end

--[=[
	Encodes a run's payloads, or raises `valueRefused` at the caller's line.

	@param w         the writer, unchanged when a value is refused
	@param codec     the messages' codec, a definition's `data`
	@param values    the messages' values, at 1 to `count`
	@param count     how many messages, at least 1
	@param instances the chunk's instances, listed by `Run.collect`
	@param subject   the definition and call, such as `arena.strike:fire`
	@error valueRefused, naming `subject` and the refused value's path from `data`
]=]
function Run.encode(
	w: Bits.Writer,
	codec: Ir.Codec,
	values: { any },
	count: number,
	instances: Rows.Instances,
	subject: string
)
	local startBit = w.bit
	local startTailCount = #w.tail
	local startTailBytes = w.tailBytes
	local refusal = write(w, codec, values, count, instances)
	if refusal == nil then
		return
	end

	Leaves.reset(w, startBit, startTailCount, startTailBytes)
	Leaves.raise(refusal, subject)
end

return table.freeze(Run)
