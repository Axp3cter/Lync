--!strict
--!optimize 2
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe("enum", function(): ()
    it("first variant", function(): ()
        local c = Lync.enum("Idle", "Walk", "Run")
        expect(roundTrip(c, "Idle")):toBe("Idle")
    end)
    it("last variant", function(): ()
        local c = Lync.enum("Idle", "Walk", "Run")
        expect(roundTrip(c, "Run")):toBe("Run")
    end)
    it("1 byte for <=256 variants", function(): ()
        local c = Lync.enum("A", "B", "C")
        local _, w = roundTrip(c, "A")
        expect(w):toBe(1)
    end)
    it("throws on unknown variant", function(): ()
        expect(function(): ()
            local c = Lync.enum("A", "B")
            local Channel = require(script.Parent.Parent.Parent.internal.Channel)
            local ch = Channel.create()
            c.write(ch, "C")
        end):toThrow("Invalid enum")
    end)
end)

describe("enum many variants", function(): ()
    it("256 variants = 1 byte", function(): ()
        local args = {}
        for i = 1, 256 do
            args[i] = "v" .. i
        end
        local c = Lync.enum(table.unpack(args))
        local _, w = roundTrip(c, "v128")
        expect(w):toBe(1)
    end)
end)

return nil
