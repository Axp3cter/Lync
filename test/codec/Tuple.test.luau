--!strict
--!optimize 2
local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe ("tuple", function (): ()
    it ("two elements", function (): ()
        local c = Lync.tuple (Lync.u8, Lync.string)
        local r = roundTrip (c, { 42, "hello" })
        expect (r[1]):toBe (42)
        expect (r[2]):toBe ("hello")
    end)
    it ("three elements", function (): ()
        local c = Lync.tuple (Lync.u8, Lync.u16, Lync.f32)
        local r = roundTrip (c, { 1, 1000, 3.14 })
        expect (r[1]):toBe (1)
        expect (r[2]):toBe (1000)
        expect (r[3]):toBeCloseTo (3.14)
    end)
    it ("single element", function (): ()
        local c = Lync.tuple (Lync.bool)
        local r = roundTrip (c, { true })
        expect (r[1]):toBe (true)
    end)
end)

return nil
