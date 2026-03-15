--!strict
--!optimize 2
-- Enum.test.luau — Round-trip tests for string enum codec.

local Runner  = require(script.Parent.Parent.Runner)
local Channel = require(script.Parent.Parent.Parent.core.Channel)
local Lync    = require(script.Parent.Parent.Parent)

local describe  = Runner.describe
local it        = Runner.it
local expect    = Runner.expect
local roundTrip = Runner.roundTrip

-- Tests ------------------------------------------------------------------

describe("Enum", function(): ()
    local codec = Lync.enum("idle", "walking", "running", "dead")

    it("round-trips first variant", function(): ()
        expect(roundTrip(codec, "idle")):toBe("idle")
    end)
    it("round-trips last variant", function(): ()
        expect(roundTrip(codec, "dead")):toBe("dead")
    end)
    it("round-trips middle variant", function(): ()
        expect(roundTrip(codec, "walking")):toBe("walking")
    end)
    it("uses exactly 1 byte", function(): ()
        local _, written, _ = roundTrip(codec, "running")
        expect(written):toBe(1)
    end)
    it("throws on invalid value", function(): ()
        expect(function(): ()
            local ch = Channel.create()
            codec.write(ch, "flying")
        end):toThrow("Invalid enum value")
    end)
    it("throws on duplicate definition", function(): ()
        expect(function(): ()
            Lync.enum("a", "b", "a")
        end):toThrow("Duplicate enum value")
    end)
    it("throws on empty definition", function(): ()
        expect(function(): ()
            Lync.enum()
        end):toThrow("at least one value")
    end)
end)

return nil
