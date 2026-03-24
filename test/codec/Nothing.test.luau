--!strict
--!optimize 2
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe("nothing", function(): ()
    it("writes 0 bytes", function(): ()
        local _, w = roundTrip(Lync.nothing, nil)
        expect(w):toBe(0)
    end)
    it("reads nil", function(): ()
        expect(roundTrip(Lync.nothing, nil)):toBeNil()
    end)
    it("_size = 0", function(): ()
        expect((Lync.nothing :: any)._size):toBe(0)
    end)
    it("has _directWrite", function(): ()
        expect((Lync.nothing :: any)._directWrite):toBeTruthy()
    end)
    it("has _directRead", function(): ()
        expect((Lync.nothing :: any)._directRead):toBeTruthy()
    end)
end)

return nil
