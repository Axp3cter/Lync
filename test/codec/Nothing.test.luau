--!strict
--!optimize 2
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe("nothing", function(): ()
    it("returns nil", function(): ()
        expect(roundTrip(Lync.nothing, nil)):toBeNil()
    end)
    it("0 bytes", function(): ()
        local _, w = roundTrip(Lync.nothing, nil)
        expect(w):toBe(0)
    end)
    it("_size = 0", function(): ()
        expect((Lync.nothing :: any)._size):toBe(0)
    end)
    it("ignores input", function(): ()
        expect(roundTrip(Lync.nothing, 42)):toBeNil()
    end)
end)

return nil
