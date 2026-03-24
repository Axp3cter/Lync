--!strict
--!optimize 2
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe("enum", function(): ()
    it("round-trips each variant", function(): ()
        local c = Lync.enum("idle", "moving", "attacking", "dead")
        expect(roundTrip(c, "idle")):toBe("idle")
        expect(roundTrip(c, "moving")):toBe("moving")
        expect(roundTrip(c, "attacking")):toBe("attacking")
        expect(roundTrip(c, "dead")):toBe("dead")
    end)
    it("_size = 1", function(): () expect((Lync.enum("a", "b") :: any)._size):toBe(1) end)
    it("single variant", function(): () expect(roundTrip(Lync.enum("only"), "only")):toBe("only") end)
    it("preserves alphabetical independence (order doesn't matter to user)", function(): ()
        local c = Lync.enum("z", "a", "m")
        expect(roundTrip(c, "z")):toBe("z")
        expect(roundTrip(c, "a")):toBe("a")
        expect(roundTrip(c, "m")):toBe("m")
    end)
    it("rejects unknown value on write", function(): ()
        expect(function(): () Lync.enum("a", "b").write(Channel.create(), "c") end):toThrow("invalid value")
    end)
    it("rejects duplicate values", function(): () expect(function(): () Lync.enum("a", "b", "a") end):toThrow("duplicate") end)
    it("rejects empty", function(): () expect(function(): () Lync.enum() end):toThrow("at least one") end)
    it("has _directWrite", function(): () expect((Lync.enum("a") :: any)._directWrite):toBeTruthy() end)
    it("_typeCheck = string", function(): () expect((Lync.enum("a") :: any)._typeCheck):toBe("string") end)
end)

return nil
