--!strict

--[=[
	buckets.spec

	Token buckets (v5.md §5.4): they start full, refill continuously up to their capacity, and
	a refused take keeps what the bucket holds.
]=]

-- Imports -----------------------------------------------------------------------------------------

local Buckets = require("../../src/session/buckets")
local Check = require("../support/check")

-- Tests -------------------------------------------------------------------------------------------

return {
	["a bucket starts full"] = function()
		local bucket = Buckets.new(5, 10, 100)
		Check.expectEqual(Buckets.peek(bucket, 100), 10, "tokens")
		for i = 1, 10 do
			Check.expect(Buckets.take(bucket, 1, 100), `take {i}`)
		end
		Check.expect(not Buckets.take(bucket, 1, 100), "an empty bucket refuses")
	end,

	["a bucket refills continuously, by rate times elapsed time"] = function()
		local bucket = Buckets.new(4, 10, 0)
		Check.expect(Buckets.take(bucket, 10, 0), "empty it")
		Check.expectEqual(Buckets.peek(bucket, 0.125), 0.5, "after 0.125 s")
		Check.expect(not Buckets.take(bucket, 1, 0.125), "half a token is not one")
		Check.expect(Buckets.take(bucket, 1, 0.25), "the refused take kept its half")
		Check.expectEqual(Buckets.peek(bucket, 0.25), 0, "taken")
		Check.expectEqual(Buckets.peek(bucket, 1.25), 4, "after another second")
	end,

	["a bucket never holds more than its capacity"] = function()
		local bucket = Buckets.new(1000, 3, 0)
		Check.expect(Buckets.take(bucket, 2, 0), "take 2")
		Check.expectEqual(Buckets.peek(bucket, 60), 3, "capped")
		Check.expect(not Buckets.take(bucket, 4, 60), "past the capacity")
		Check.expect(Buckets.take(bucket, 3, 60), "the capacity")
	end,

	["peek leaves the bucket as it was"] = function()
		local bucket = Buckets.new(1, 5, 0)
		Buckets.take(bucket, 5, 0)
		Buckets.peek(bucket, 3)
		Check.expectEqual(bucket, { rate = 1, capacity = 5, tokens = 0, at = 0 }, "bucket")
	end,
}
