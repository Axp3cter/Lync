--!strict
--!optimize 2
local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe ("custom", function (): ()
    it ("round-trips u24", function (): ()
        local c = Lync.custom (3, function (b: buffer, offset: number, value: number): ()
            buffer.writeu8 (b, offset, bit32.band (value, 0xFF))
            buffer.writeu8 (b, offset + 1, bit32.band (bit32.rshift (value, 8), 0xFF))
            buffer.writeu8 (b, offset + 2, bit32.band (bit32.rshift (value, 16), 0xFF))
        end, function (b: buffer, offset: number): number
            return buffer.readu8 (b, offset)
                + buffer.readu8 (b, offset + 1) * 256
                + buffer.readu8 (b, offset + 2) * 65536
        end)
        expect (roundTrip (c, 0)):toBe (0)
        expect (roundTrip (c, 16777215)):toBe (16777215)
        expect (roundTrip (c, 123456)):toBe (123456)
    end)
    it ("3 bytes", function (): ()
        local c = Lync.custom (3, function (b: buffer, o: number, v: number): ()
            buffer.writeu8 (b, o, v)
        end, function (b: buffer, o: number): number
            return buffer.readu8 (b, o)
        end)
        local _, w = roundTrip (c, 1)
        expect (w):toBe (3)
    end)
    it ("_size matches", function (): ()
        local c = Lync.custom (7, function () end, function ()
            return nil
        end)
        expect ((c :: any)._size):toBe (7)
    end)
end)

return nil
