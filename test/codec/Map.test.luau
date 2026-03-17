--!strict
--!optimize 2
local Baseline = require (script.Parent.Parent.Parent.internal.Baseline)
local Channel = require (script.Parent.Parent.Parent.internal.Channel)
local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe ("map", function (): ()
    it ("empty", function (): ()
        local c = Lync.map (Lync.string, Lync.u8)
        local r = roundTrip (c, {})
        local count = 0
        for _ in r do
            count += 1
        end
        expect (count):toBe (0)
    end)
    it ("string keys", function (): ()
        local c = Lync.map (Lync.string, Lync.u8)
        local r = roundTrip (c, { hp = 100, mp = 50 })
        expect (r.hp):toBe (100)
        expect (r.mp):toBe (50)
    end)
    it ("numeric keys", function (): ()
        local c = Lync.map (Lync.u8, Lync.string)
        local r = roundTrip (c, { [1] = "one", [2] = "two" })
        expect (r[1]):toBe ("one")
        expect (r[2]):toBe ("two")
    end)
end)

describe ("map maxCount", function (): ()
    it ("rejects over limit", function (): ()
        expect (function (): ()
            local c = Lync.map (Lync.string, Lync.u8, 1)
            local ch = Channel.create ()
            c.write (ch, { a = 1, b = 2 })
            local buf = buffer.create (ch.cursor)
            buffer.copy (buf, 0, ch.buff, 0, ch.cursor)
            c.read (buf, 0, nil)
        end):toThrow ("exceeds max")
    end)
end)

describe ("deltaMap", function (): ()
    it ("full round-trip", function (): ()
        Baseline.setReadKey (false)
        local c = Lync.deltaMap (Lync.string, Lync.u8)
        local r = roundTrip (c, { a = 1, b = 2 })
        expect (r.a):toBe (1)
        expect (r.b):toBe (2)
    end)
    it ("identical write is smaller", function (): ()
        Baseline.setReadKey (false)
        local c = Lync.deltaMap (Lync.string, Lync.u8)
        local ch = Channel.create ()
        c.write (ch, { a = 1, b = 2 })
        local w1 = ch.cursor
        ch.cursor = 0
        c.write (ch, { a = 1, b = 2 })
        expect (ch.cursor):toBeLessThan (w1)
    end)
end)

return nil
