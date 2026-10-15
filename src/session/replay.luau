--!strict

--[=[
	Replay

	The upstream unreliable replay window (v5.md §4.5): a 64-frame RFC 4303 bitmap over extended
	seqs. A seq newer than the newest slides the window; one inside it is new unless already
	seen; one older than the window is dropped.

	The bitmap is two u32 words: bit i of `low`, then of `high` from i = 32, is set when the seq
	`newest - i` was accepted.
]=]

-- Module ------------------------------------------------------------------------------------------

local Replay = {}

-- Types -------------------------------------------------------------------------------------------

--[=[
	One client's window.

	@field newest the newest accepted seq, -1 before the first
	@field low    the bitmap's bits 0 to 31
	@field high   the bitmap's bits 32 to 63
]=]
export type Window = {
	newest: number,
	low: number,
	high: number,
}

-- Constants ---------------------------------------------------------------------------------------

const WINDOW_FRAMES = 64
const WORD_BITS = 32

const STATUS_NEW = 0
const STATUS_SEEN = 1
const STATUS_OLD = 2

-- Public ------------------------------------------------------------------------------------------

--[=[
	Creates an empty window.

	@return a window in which every seq is new
]=]
function Replay.new(): Window
	return { newest = -1, low = 0, high = 0 }
end

--[=[
	Records a seq as received, after its tag verified.

	@param w    the window
	@param full the extended seq, whose status is 0 (new)
]=]
function Replay.accept(w: Window, full: number)
	local shift = full - w.newest
	if shift <= 0 then
		local behind = -shift
		if behind < WORD_BITS then
			w.low = bit32.bor(w.low, bit32.lshift(1, behind))
		else
			w.high = bit32.bor(w.high, bit32.lshift(1, behind - WORD_BITS))
		end
		return
	end

	if shift >= WINDOW_FRAMES then
		w.high = 0
		w.low = 1
	elseif shift >= WORD_BITS then
		w.high = bit32.lshift(w.low, shift - WORD_BITS)
		w.low = 1
	else
		w.high = bit32.bor(bit32.lshift(w.high, shift), bit32.rshift(w.low, WORD_BITS - shift))
		w.low = bit32.bor(bit32.lshift(w.low, shift), 1)
	end
	w.newest = full
end

--[=[
	Returns the newest accepted seq.

	@param  w the window
	@return the newest accepted extended seq, -1 before the first; `Seq.extend` extends against it
]=]
function Replay.newest(w: Window): number
	return w.newest
end

--[=[
	Returns whether a seq is new, already seen, or older than the window.

	@param  w    the window
	@param  full the extended seq
	@return 0 new, 1 seen, 2 older than the window
]=]
function Replay.status(w: Window, full: number): number
	local behind = w.newest - full
	if behind < 0 then
		return STATUS_NEW
	end

	if behind >= WINDOW_FRAMES then
		return STATUS_OLD
	end

	local word = if behind < WORD_BITS then w.low else w.high
	if bit32.btest(word, bit32.lshift(1, behind % WORD_BITS)) then
		return STATUS_SEEN
	end

	return STATUS_NEW
end

return table.freeze(Replay)
