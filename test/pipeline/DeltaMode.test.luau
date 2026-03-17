--!strict
--!optimize 2

local Baseline = require (script.Parent.Parent.Parent.internal.Baseline)
local Channel = require (script.Parent.Parent.Parent.internal.Channel)
local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe ("delta round-trip", function (): ()
    it ("full round-trip struct", function (): ()
        Baseline.setReadKey (false)
        local c = Lync.deltaStruct ({ hp = Lync.u8, mp = Lync.u8 })
        local r = roundTrip (c, { hp = 100, mp = 50 })
        expect (r.hp):toBe (100)
        expect (r.mp):toBe (50)
    end)
    it ("full round-trip array", function (): ()
        Baseline.setReadKey (false)
        local c = Lync.deltaArray (Lync.u16)
        local r = roundTrip (c, { 100, 200, 300 })
        expect (#r):toBe (3)
        expect (r[2]):toBe (200)
    end)
    it ("full round-trip map", function (): ()
        Baseline.setReadKey (false)
        local c = Lync.deltaMap (Lync.string, Lync.u8)
        local r = roundTrip (c, { a = 1, b = 2 })
        expect (r.a):toBe (1)
        expect (r.b):toBe (2)
    end)
end)

describe ("delta compression", function (): ()
    it ("struct shrinks", function (): ()
        Baseline.setReadKey (false)
        local c = Lync.deltaStruct ({ hp = Lync.u8, mp = Lync.u8, sp = Lync.u8 })
        local ch = Channel.create ()
        c.write (ch, { hp = 100, mp = 50, sp = 25 })
        local w1 = ch.cursor
        ch.cursor = 0
        c.write (ch, { hp = 100, mp = 50, sp = 25 })
        expect (ch.cursor):toBeLessThan (w1)
    end)
    it ("array shrinks", function (): ()
        Baseline.setReadKey (false)
        local c = Lync.deltaArray (Lync.u8)
        local ch = Channel.create ()
        c.write (ch, { 1, 2, 3, 4, 5 })
        local w1 = ch.cursor
        ch.cursor = 0
        c.write (ch, { 1, 2, 3, 4, 5 })
        expect (ch.cursor):toBeLessThan (w1)
    end)
end)

return nil
