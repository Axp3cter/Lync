--!strict
--!optimize 2
local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe ("Custom", function (): ()
    local codec = Lync.custom (4, function (b: buffer, offset: number, value: number): ()
        buffer.writef32 (b, offset, value)
    end, function (b: buffer, offset: number): number
        return buffer.readf32 (b, offset)
    end)

    it ("round-trips positive", function (): ()
        local r = roundTrip (codec, 3.14)
        expect (r):toBeCloseTo (3.14)
    end)
    it ("round-trips zero", function (): ()
        local r = roundTrip (codec, 0)
        expect (r):toBe (0)
    end)
    it ("round-trips negative", function (): ()
        local r = roundTrip (codec, -999.5)
        expect (r):toBeCloseTo (-999.5)
    end)
    it ("uses 4 bytes", function (): ()
        local _, w = roundTrip (codec, 1)
        expect (w):toBe (4)
    end)
    it ("_size is 4", function (): ()
        expect ((codec :: any)._size):toBe (4)
    end)
    it ("has _directWrite and _directRead", function (): ()
        expect ((codec :: any)._directWrite):toBeTruthy ()
        expect ((codec :: any)._directRead):toBeTruthy ()
    end)

    describe ("zero-size", function (): ()
        local zeroCodec = Lync.custom (
            0,
            function (_b: buffer, _offset: number, _v: any): () end,
            function (_b: buffer, _offset: number): any
                return nil
            end
        )

        it ("_size is 0", function (): ()
            expect ((zeroCodec :: any)._size):toBe (0)
        end)
        it ("round-trips as nil", function (): ()
            local r, w = roundTrip (zeroCodec, nil)
            expect (r):toBe (nil)
            expect (w):toBe (0)
        end)
    end)
end)

return nil
