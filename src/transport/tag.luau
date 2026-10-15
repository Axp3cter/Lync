--!strict

--[=[
	Tag

	The keyed tag that ends every tagged upstream frame (v5.md §4.5): the low 16 bits of
	HalfSipHash-1-3, 32-bit output, little-endian after the frame's last byte.

	The hash input is the frame count (reliable) or extended seq (unreliable) as u32le, the lane
	as u8, the frame's length before the tag as u32le, its instance count as u16le, then the first
	min(`tag.cover`, length) bytes of the frame.
]=]

-- Imports -----------------------------------------------------------------------------------------

local HalfSipHash = require("../wire/halfsiphash")
local Host = require("../host/host")

-- Module ------------------------------------------------------------------------------------------

local Tag = {}

-- Constants ---------------------------------------------------------------------------------------

const TAG_BYTES = 2
const TAG_RANGE = 0x1_0000
const COUNT_RANGE = 0x1_0000_0000
const INSTANCE_COUNT_RANGE = 0x1_0000

--- The bytes before the covered frame bytes: count, lane, length and instance count.
const PREFIX_BYTES = 11

--- The most bytes `tag.cover` covers (v5.md §7.5).
const MAX_COVER = 16_384

const COMPRESSION_ROUNDS = 1
const FINALIZATION_ROUNDS = 3
const OUTPUT_BYTES = 4

--- The hash input, rebuilt for every tag.
const SCRATCH = buffer.create(PREFIX_BYTES + MAX_COVER)

-- Public ------------------------------------------------------------------------------------------

--[=[
	Appends a tag to a frame.

	@param  frame the frame before the tag
	@param  tag   the tag, from `Tag.compute`
	@return a new buffer: the frame, then the tag as u16le
]=]
function Tag.append(frame: buffer, tag: number): buffer
	local length = buffer.len(frame)
	local tagged = buffer.create(length + TAG_BYTES)
	buffer.copy(tagged, 0, frame)
	buffer.writeu16(tagged, length, tag)

	return tagged
end

--[=[
	Computes a frame's tag.

	@param  key           the 8-byte tag key
	@param  count         the frame count (reliable) or the extended seq (unreliable), taken mod
	                      2^32
	@param  lane          the remote the frame goes on
	@param  frame         the frame; bytes past `length` are not read
	@param  length        the frame's length before the tag
	@param  instanceCount how many instances the call carries, taken mod 2^16
	@param  cover         `tag.cover`, 0 to 16,384
	@return the tag, 0 to 65535
]=]
function Tag.compute(
	key: buffer,
	count: number,
	lane: Host.Lane,
	frame: buffer,
	length: number,
	instanceCount: number,
	cover: number
): number
	local covered = math.min(cover, length)
	buffer.writeu32(SCRATCH, 0, count % COUNT_RANGE)
	buffer.writeu8(SCRATCH, 4, lane)
	buffer.writeu32(SCRATCH, 5, length)
	buffer.writeu16(SCRATCH, 9, instanceCount % INSTANCE_COUNT_RANGE)
	buffer.copy(SCRATCH, PREFIX_BYTES, frame, 0, covered)

	local low = HalfSipHash.hash(
		key,
		SCRATCH,
		0,
		PREFIX_BYTES + covered,
		COMPRESSION_ROUNDS,
		FINALIZATION_ROUNDS,
		OUTPUT_BYTES
	)

	return low % TAG_RANGE
end

--[=[
	Returns the tag a frame ends with.

	@param  frame the tagged frame, at least 2 bytes (`Frame.open` refuses shorter ones)
	@return the frame's last two bytes as u16le
]=]
function Tag.read(frame: buffer): number
	return buffer.readu16(frame, buffer.len(frame) - TAG_BYTES)
end

return table.freeze(Tag)
