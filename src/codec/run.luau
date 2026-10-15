--!strict

--[=[
	Run

	The payloads of a run of messages of one definition (v5.md §4.3): fewer than `Column.MIN_ROWS`
	messages are single rows one after another, more are one column block. The decoder knows the
	form from the count, so no flag is sent.

	A run's chunk header (`id`, `count - 1`, `instances`, §4.1) belongs to the transport. Its
	instance list must be known before the payloads are written, since indices are as wide as the
	list needs, so `Run.collect` lists them first; the transport brackets the decode with
	`Rows.beginChunk` and `Rows.endChunk` (m1-plan.md §6.2).
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
	Lists a run's instances, each once, in the order the payloads reference them first, and
	writes nothing. A value the codec would refuse lists nothing past it.

	@param codec  the messages' codec
	@param values the messages' values, at 1 to `count`
	@param count  how many messages
	@param into   the chunk's instances, extended
]=]
function Run.collect(codec: Ir.Codec, values: { any }, count: number, into: Rows.Instances)
	if count >= Column.MIN_ROWS then
		Columns.collect(codec, values, 1, count, into)
		return
	end

	for i = 1, count do
		Rows.collect(codec, values[i], into)
	end
end

--[=[
	Decodes a run's payloads, after its chunk header; the caller begins and ends the chunk.

	@param  r      the reader; its budget is charged for the run's count and every array and map
	               count
	@param  codec  the messages' codec
	@param  count  how many messages, from the header
	@param  chunk  the chunk's instances
	@param  misses where values the receiver can't resolve are recorded, by message number
	@param  out    where the values are stored, at 1 to `count`
	@return 0, or the v5.md §4.8 rule that refuses the run
]=]
function Run.decode(
	r: Bits.Reader,
	codec: Ir.Codec,
	count: number,
	chunk: Rows.Chunk,
	misses: { Rows.Miss },
	out: { any }
): number
	if not Bits.charge(r, count) then
		return 10
	end

	if count >= Column.MIN_ROWS then
		local rows: { number }? = nil
		if Leaves.canMiss(codec) then
			local numbers = table.create(count, 0)
			for i = 1, count do
				numbers[i] = i
			end
			rows = numbers
		end

		return Columns.read(r, codec, count, chunk, misses, out, 0, rows)
	end

	for i = 1, count do
		local value, rule = Rows.read(r, codec, chunk, i, misses)
		if rule ~= 0 then
			return rule
		end
		out[i] = value
	end

	return 0
end

--[=[
	Encodes a run's payloads, or raises at the caller's line.

	The chunk's instances must already list the run's instances (`Run.collect`). On any failure
	the writer and the instance list are as they were before the last committed encode.

	@param w         the writer
	@param codec     the messages' codec
	@param values    the messages' values, at 1 to `count`
	@param count     how many messages, at least 1
	@param instances the chunk's instances; the encode commits what is listed
	@param subject   the definition and call, such as `arena.strike:fire`
	@param root      the value the refusal's path starts from
	@error valueRefused, naming `subject` and the refused value's path from `root`; a raise from
	       game code (`t.convert`, `t.custom`) or `internal`, unchanged
]=]
function Run.encode(
	w: Bits.Writer,
	codec: Ir.Codec,
	values: { any },
	count: number,
	instances: Rows.Instances,
	subject: string,
	root: Rows.Root
)
	local startBit = w.bit
	local startTailCount = #w.tail
	local startTailBytes = w.tailBytes
	local committed = instances.count
	instances.count = #instances.list

	local ok, result = pcall(write, w, codec, values, count, instances)
	if ok and result == nil then
		return
	end

	Leaves.rollBack(w, startBit, startTailCount, startTailBytes, instances, committed)
	if not ok then
		error(result, 0)
	end
	Leaves.raise(result :: Rows.Refusal, subject, root)
end

return table.freeze(Run)
