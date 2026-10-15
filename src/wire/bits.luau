--!strict

--[=[
	Bits

	Bit I/O for frames: a bit section written least significant bit first (bit i is bit i mod 8 of
	byte i // 8, v5.md §4.1), followed by a tail of string and buffer bytes read backwards from the
	end (§4.2).

	Fields are 0 to 53 bits wide; wider integers are split by the caller. Fields of up to 24 bits
	are written and read as one u32 window at the field's first byte, so the writer keeps 4 spare
	bytes past its last field and the reader assembles the window from single bytes near the
	buffer's end.

	A writer's state is its `bit` and the length of its `tail`: an encoder marks both and resets
	them to undo what it wrote, so nothing at or past `bit` is ever assumed to be zero. Readers
	return nil (or false) where bits run out or padding is not zero, so decoding never raises.
]=]

-- Module ------------------------------------------------------------------------------------------

local Bits = {}

-- Types -------------------------------------------------------------------------------------------

--[=[
	A growing bit section and its tail.

	@field buf       the bit section, doubled as it grows; bits at or past `bit` are undefined
	@field bit       the next bit to write
	@field tail      tail values in decode order
	@field tailBytes the total length of `tail`'s values
]=]
export type Writer = {
	buf: buffer,
	bit: number,
	tail: { string | buffer },
	tailBytes: number,
}

--[=[
	A cursor over one frame's bits and tail.

	@field buf    the frame
	@field bit    the absolute next bit to read
	@field stop   the tail cursor: the byte after the next tail value to read
	@field budget the decode element allowance left (v5.md §4.8 rule 10); math.huge on clients
]=]
export type Reader = {
	buf: buffer,
	bit: number,
	stop: number,
	budget: number,
}

-- Constants ---------------------------------------------------------------------------------------

const INITIAL_BYTES = 64
const WINDOW_BYTES = 4

--- The widest field a u32 window holds at any bit offset within its first byte.
const CHUNK_BITS = 24
const CHUNK_RANGE = 0x100_0000

-- Private -----------------------------------------------------------------------------------------

local function writeChunk(buf: buffer, bit: number, value: number)
	local byte = bit // 8
	local shift = bit % 8
	local below = bit32.band(buffer.readu32(buf, byte), bit32.lshift(1, shift) - 1)
	buffer.writeu32(buf, byte, bit32.bor(below, bit32.lshift(value, shift)))
end

-- The u32 window at `byte` when fewer than 4 bytes remain, from the bytes that do.
local function windowNearEnd(buf: buffer, byte: number): number
	local window = 0
	for i = 0, buffer.len(buf) - byte - 1 do
		window += bit32.lshift(buffer.readu8(buf, byte + i), 8 * i)
	end

	return window
end

local function readChunk(buf: buffer, bit: number, width: number): number
	if width == 0 then
		return 0
	end

	local byte = bit // 8
	if byte + WINDOW_BYTES <= buffer.len(buf) then
		return bit32.extract(buffer.readu32(buf, byte), bit % 8, width)
	end

	return bit32.extract(windowNearEnd(buf, byte), bit % 8, width)
end

local function grow(w: Writer, neededBytes: number)
	local length = buffer.len(w.buf)
	while length < neededBytes do
		length *= 2
	end

	local grown = buffer.create(length)
	buffer.copy(grown, 0, w.buf)
	w.buf = grown
end

local function copyBits(w: Writer, into: buffer)
	local bitBytes = (w.bit + 7) // 8
	buffer.copy(into, 0, w.buf, 0, bitBytes)

	local usedBits = w.bit % 8
	if usedBits > 0 then
		local last = buffer.readu8(into, bitBytes - 1)
		buffer.writeu8(into, bitBytes - 1, bit32.band(last, bit32.lshift(1, usedBits) - 1))
	end
end

local function copyTail(w: Writer, into: buffer, at: number)
	local tail = w.tail
	for i = #tail, 1, -1 do
		local value = tail[i]
		if typeof(value) == "string" then
			buffer.writestring(into, at, value)
			at += #value
		else
			buffer.copy(into, at, value)
			at += buffer.len(value)
		end
	end
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Writes zero bits up to the next byte boundary.

	@param w the writer
]=]
function Bits.align(w: Writer)
	Bits.write(w, (8 - w.bit % 8) % 8, 0)
end

--[=[
	Charges elements to the reader's decode element allowance, before they are allocated.

	@param  r the reader, its budget reduced by `n`
	@param  n how many elements: a run, array or map count
	@return false when the allowance has gone negative, which refuses the frame (rule 10)
]=]
function Bits.charge(r: Reader, n: number): boolean
	local budget = r.budget - n
	r.budget = budget

	return budget >= 0
end

--[=[
	Appends bits from a buffer, at any bit offset and with no alignment (v5.md §4.1, upstream
	chunks).

	@param w         the writer
	@param from      the bits to copy, starting at its bit 0
	@param bitLength how many bits to copy, at most 8 times the length of `from`
]=]
function Bits.copy(w: Writer, from: buffer, bitLength: number)
	local bit = w.bit
	local neededBytes = (bit + bitLength) // 8 + WINDOW_BYTES
	if neededBytes > buffer.len(w.buf) then
		grow(w, neededBytes)
	end

	local buf = w.buf
	local copied = 0
	while bitLength - copied > CHUNK_BITS do
		writeChunk(buf, bit + copied, readChunk(from, copied, CHUNK_BITS))
		copied += CHUNK_BITS
	end
	writeChunk(buf, bit + copied, readChunk(from, copied, bitLength - copied))

	w.bit = bit + bitLength
end

--[=[
	Returns the writer's bits and tail as one frame body.

	@param  w the writer, unchanged
	@return the aligned bit section followed by the tail segment
]=]
function Bits.finish(w: Writer): buffer
	local bitBytes = (w.bit + 7) // 8
	local frame = buffer.create(bitBytes + w.tailBytes)
	copyBits(w, frame)
	copyTail(w, frame, bitBytes)

	return frame
end

--[=[
	Returns whether the bits read so far end exactly where the tail begins, with zero padding
	(v5.md §4.8 rule 4).

	@param  r the reader, unchanged
	@return true when ceil(bit / 8) is the tail cursor and every padding bit is 0
]=]
function Bits.meets(r: Reader): boolean
	local bitBytes = (r.bit + 7) // 8
	if bitBytes ~= r.stop then
		return false
	end

	return readChunk(r.buf, r.bit, (8 - r.bit % 8) % 8) == 0
end

--[=[
	Returns the writer's bit section and tail segment as separate buffers.

	@param  w the writer, unchanged
	@return the bit section, zero-padded to a byte boundary
	@return the tail segment: the tail values in reverse decode order (v5.md §4.2)
]=]
function Bits.parts(w: Writer): (buffer, buffer)
	local bitSection = buffer.create((w.bit + 7) // 8)
	copyBits(w, bitSection)

	local tailSegment = buffer.create(w.tailBytes)
	copyTail(w, tailSegment, 0)

	return bitSection, tailSegment
end

--[=[
	Reads an unsigned field.

	@param  r     the reader, advanced past the field when it fits
	@param  width the field's width in bits, 0 to 53
	@return the field's value, or nil when it would pass the tail cursor
]=]
function Bits.read(r: Reader, width: number): number?
	local bit = r.bit
	local finish = bit + width
	if finish > r.stop * 8 then
		return nil
	end

	r.bit = finish
	local buf = r.buf
	if width <= CHUNK_BITS then
		return readChunk(buf, bit, width)
	end

	local value = 0
	local scale = 1
	local remaining = width
	while remaining > CHUNK_BITS do
		value += readChunk(buf, bit, CHUNK_BITS) * scale
		scale *= CHUNK_RANGE
		bit += CHUNK_BITS
		remaining -= CHUNK_BITS
	end

	return value + readChunk(buf, bit, remaining) * scale
end

--[=[
	Skips the padding up to the next byte boundary.

	@param  r the reader, advanced to the boundary
	@return false when a padding bit is 1
]=]
function Bits.readAlign(r: Reader): boolean
	local bit = r.bit
	local paddingBits = (8 - bit % 8) % 8
	r.bit = bit + paddingBits

	return readChunk(r.buf, bit, paddingBits) == 0
end

--[=[
	Creates a reader over part of a buffer.

	@param  buf       the frame
	@param  startByte the first byte of the bit section, 0 when nil
	@param  stopByte  the byte after the tail's last byte, the buffer's length when nil
	@param  budget    the frame's decode element allowance, unlimited when nil
	@return a reader at the first bit, with its tail cursor at `stopByte`
]=]
function Bits.reader(buf: buffer, startByte: number?, stopByte: number?, budget: number?): Reader
	return {
		buf = buf,
		bit = (startByte or 0) * 8,
		stop = stopByte or buffer.len(buf),
		budget = budget or math.huge,
	}
end

--[=[
	Reads the tail value that ends at the tail cursor.

	@param  r        the reader, its tail cursor moved back by `length` when the value fits
	@param  length   the value's length in bytes
	@param  asBuffer whether the value is returned as a buffer rather than a string
	@return the value, or nil when it would overlap the bits read so far
]=]
function Bits.readTail(r: Reader, length: number, asBuffer: boolean): (string | buffer)?
	local start = r.stop - length
	if start < (r.bit + 7) // 8 then
		return nil
	end

	r.stop = start
	if not asBuffer then
		return buffer.readstring(r.buf, start, length)
	end

	local value = buffer.create(length)
	buffer.copy(value, 0, r.buf, start, length)

	return value
end

--[=[
	Writes an unsigned field.

	@param w     the writer
	@param width the field's width in bits, 0 to 53
	@param value an integer in [0, 2^width)
]=]
function Bits.write(w: Writer, width: number, value: number)
	local bit = w.bit
	local neededBytes = (bit + width) // 8 + WINDOW_BYTES
	if neededBytes > buffer.len(w.buf) then
		grow(w, neededBytes)
	end

	local buf = w.buf
	local remaining = width
	while remaining > CHUNK_BITS do
		writeChunk(buf, bit, value % CHUNK_RANGE)
		value //= CHUNK_RANGE
		bit += CHUNK_BITS
		remaining -= CHUNK_BITS
	end
	writeChunk(buf, bit, value)

	w.bit = bit + remaining
end

--[=[
	Appends a value to the tail.

	@param w     the writer
	@param value the bytes, appended in decode order
]=]
function Bits.writeTail(w: Writer, value: string | buffer)
	table.insert(w.tail, value)
	w.tailBytes += if typeof(value) == "string" then #value else buffer.len(value)
end

--[=[
	Creates an empty writer.

	@return a writer with no bits and no tail
]=]
function Bits.writer(): Writer
	return {
		buf = buffer.create(INITIAL_BYTES),
		bit = 0,
		tail = {},
		tailBytes = 0,
	}
end

return table.freeze(Bits)
