--!strict
--!optimize 2
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe("bool", function(): ()
    it("true", function(): ()
        expect(roundTrip(Lync.bool, true)):toBe(true)
    end)
    it("false", function(): ()
        expect(roundTrip(Lync.bool, false)):toBe(false)
    end)
    it("1 byte", function(): ()
        local _, w = roundTrip(Lync.bool, true)
        expect(w):toBe(1)
    end)
    it("_size = 1", function(): ()
        expect((Lync.bool :: any)._size):toBe(1)
    end)
    it("_isBool flag", function(): ()
        expect((Lync.bool :: any)._isBool):toBe(true)
    end)
end)

return nil
