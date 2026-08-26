--!strict
--!optimize 2
-- The u16 ring an unreliable stream is ordered by, and the rate gate over it.

local Protocol = require ("@src/wire/Protocol")

local Sequence = {}

-- Constants -----------------------------------------------------------

const WINDOW = Protocol.NEWEST_WINDOW

-- The ring a sequence counts round, which is the window doubled.
const SPACE = WINDOW * 2

-- Public --------------------------------------------------------------

function Sequence.next (n: number): number return (n + 1) % SPACE end

--[[
    Newer is a distance under the window, so exactly half the space apart ranks neither way and a
    sequence is never newer than itself. The subtraction goes negative and the remainder follows the
    divisor, which is what carries it round the ring.
]]
function Sequence.isNewer (a: number, b: number): boolean
    local apart = (a - b) % SPACE
    return apart > 0 and apart < WINDOW
end

--[[
    The interval runs from the last transmission, never from a division of the clock: a gate reading
    the clock in buckets delivers the same rate and lets two flushes a bucket apart both through.
    Two in one instant are one transmission.
]]
function Sequence.opened (now: number, last: number?, hz: number?): boolean
    if last == nil or hz == nil then return true end
    return now - last >= 1 / hz
end

return table.freeze (Sequence)
