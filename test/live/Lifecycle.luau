--!strict
--!optimize 2
-- The phases that need a real second of waiting, which is the one thing a fake clock cannot give.

local Lync = require ("@src")
local Protocol = require ("@src/wire/Protocol")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Records = require ("@test/harness/Records")

-- Constants -----------------------------------------------------------

-- A namespace of its own, which is what makes this check possible at all.
const NAMESPACE = "detector"

-- The window is the library's, read from the one module that declares it.
const WINDOW = Protocol.DETECTOR_WINDOW

-- How long past the window a half waits, which is slack rather than a second deadline.
const SLACK = 0.5

const CARRIED = 3

--[[
    One packet, fired and deliberately never flushed. What this check leaves behind is a queue
    nobody drains, so the definition is its own rather than one another check reaches: the detector
    disarms on a flush and there is no flush here.
]]
const FORGOTTEN = "forgotten"

const DEFINITIONS = table.freeze ({
    [FORGOTTEN] = Lync.packet (Lync.int (0, 100)),
})

-- Public --------------------------------------------------------------

return {
    Harness.opens (NAMESPACE, DEFINITIONS :: any),

    --[[
        Traffic queued and never sent, which is the mistake a library cannot fix and can only
        report. A place that forgets its flush sees nothing arrive and nothing said about it, and
        the shape of that is a network that looks broken rather than a call that was not made.
    ]]
    Harness.pair ("life.detector", function ()
        local held = Records.made (function ()
            DEFINITIONS[FORGOTTEN]:fireClient (Lync.all, CARRIED)
            task.wait (WINDOW + SLACK)
        end)

        local said: Records.Held? = nil
        for _, one in held do
            if one.kind == "error" and one.data.definition == FORGOTTEN then said = one end
        end

        Expect.holds (said ~= nil, `nothing was recorded in {WINDOW + SLACK} seconds`)
        local text = (said :: Records.Held).message
        Expect.holds (
            string.find (text, "never flushed", 1, true) ~= nil,
            `the record said "{text}"`
        )
    end, function ()
        -- The client half waits it out and sends nothing, since a forgotten flush is one machine's.
        task.wait (WINDOW + SLACK)
    end),
}
