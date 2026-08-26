--!strict
--!optimize 2
-- Milliseconds against an epoch, the field they wrap into, and the instant one is unwrapped to.

local Protocol = require ("@src/wire/Protocol")

local Clock = {}

-- Constants -----------------------------------------------------------

const RATE = Protocol.STAMP_RATE
const SPAN = 2 ^ Protocol.STAMP_BITS

-- Public --------------------------------------------------------------

--[[
    Floored rather than rounded, so a count never runs ahead of the clock it read, and negative
    where the reading is behind the epoch: a client's shared clock sits there for a moment after
    start and clamping would move its stamps.
]]
function Clock.elapsed (now: number, epoch: number): number
    local since = now - epoch
    return math.floor (since * RATE)
end

-- The remainder follows the divisor, so a negative count lands inside the field, not below it.
function Clock.stamp (elapsed: number): number return elapsed % SPAN end

--[[
    The instant carrying this stamp nearest the estimate. At exactly half a space the two candidates
    tie and the rounding takes the one further from the stamp, which is arbitrary and pinned.
]]
function Clock.unwrap (stamp: number, elapsed: number): number
    return stamp + math.round ((elapsed - stamp) / SPAN) * SPAN
end

return table.freeze (Clock)
