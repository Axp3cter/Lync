--!strict
--!optimize 2
local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe ("buff", function (): ()
    it ("empty", function (): ()
        local r = roundTrip (Lync.buff, buffer.create (0))
        expect (buffer.len (r)):toBe (0)
    end)
    it ("preserves data", function (): ()
        local b = buffer.create (4)
        buffer.writeu32 (b, 0, 0xDEADBEEF)
        local r = roundTrip (Lync.buff, b)
        expect (buffer.readu32 (r, 0)):toBe (0xDEADBEEF)
    end)
    it ("preserves length", function (): ()
        local r = roundTrip (Lync.buff, buffer.create (100))
        expect (buffer.len (r)):toBe (100)
    end)
end)

return nil
