--!strict

--[=[
	Buckets

	Token buckets for the inbound budgets and `limit` on both sides (v5.md §5.4, §6.1).

	A bucket starts full and refills continuously: on each use, tokens = min(capacity, tokens +
	rate × elapsed). Times are `os.clock()` seconds, passed in, so a bucket holds no clock.
]=]

-- Module ------------------------------------------------------------------------------------------

local Buckets = {}

-- Types -------------------------------------------------------------------------------------------

--- A token bucket: `rate` tokens per second up to `capacity`, holding `tokens` at time `at`.
export type Bucket = {
	rate: number,
	capacity: number,
	tokens: number,
	at: number,
}

-- Private -----------------------------------------------------------------------------------------

local function tokensAt(bucket: Bucket, now: number): number
	return math.min(bucket.capacity, bucket.tokens + bucket.rate * (now - bucket.at))
end

-- Public ------------------------------------------------------------------------------------------

--[=[
	Creates a full bucket.

	@param  rate     tokens per second
	@param  capacity the most tokens it holds
	@param  now      the time it is created
	@return the bucket, holding `capacity` tokens
]=]
function Buckets.new(rate: number, capacity: number, now: number): Bucket
	return {
		rate = rate,
		capacity = capacity,
		tokens = capacity,
		at = now,
	}
end

--[=[
	The tokens a bucket holds at a time, refilled; the bucket is left as it was.

	@param  bucket the bucket
	@param  now    the time, no earlier than its last use
	@return the tokens it holds at `now`
]=]
function Buckets.peek(bucket: Bucket, now: number): number
	return tokensAt(bucket, now)
end

--[=[
	Refills a bucket to a time, then takes `n` tokens if it holds them.

	@param  bucket the bucket
	@param  n      the tokens to take
	@param  now    the time, no earlier than its last use
	@return whether the tokens were taken; when not, the bucket keeps its refilled tokens
]=]
function Buckets.take(bucket: Bucket, n: number, now: number): boolean
	local tokens = tokensAt(bucket, now)
	bucket.at = now
	if tokens < n then
		bucket.tokens = tokens
		return false
	end

	bucket.tokens = tokens - n
	return true
end

return table.freeze(Buckets)
