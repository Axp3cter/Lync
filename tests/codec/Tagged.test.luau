--!strict
--!optimize 2
-- Tagged.test.luau — Round-trip tests for discriminated union codec.

local Runner  = require(script.Parent.Parent.Runner)
local Channel = require(script.Parent.Parent.Parent.core.Channel)
local Lync    = require(script.Parent.Parent.Parent)

local describe  = Runner.describe
local it        = Runner.it
local expect    = Runner.expect
local roundTrip = Runner.roundTrip

-- Tests ------------------------------------------------------------------

describe("Tagged", function(): ()
    local codec = Lync.tagged("kind", {
        damage = Lync.struct({ kind = Lync.string, amount = Lync.u16 }),
        heal   = Lync.struct({ kind = Lync.string, amount = Lync.u16, source = Lync.string }),
        death  = Lync.struct({ kind = Lync.string }),
    })

    it("round-trips damage variant", function(): ()
        local result = roundTrip(codec, { kind = "damage", amount = 50 })
        expect(result.kind):toBe("damage")
        expect(result.amount):toBe(50)
    end)
    it("round-trips heal variant", function(): ()
        local result = roundTrip(codec, { kind = "heal", amount = 25, source = "potion" })
        expect(result.kind):toBe("heal")
        expect(result.amount):toBe(25)
        expect(result.source):toBe("potion")
    end)
    it("round-trips death variant", function(): ()
        local result = roundTrip(codec, { kind = "death" })
        expect(result.kind):toBe("death")
    end)
    it("throws on unknown variant", function(): ()
        expect(function(): ()
            local ch = Channel.create()
            codec.write(ch, { kind = "explode" })
        end):toThrow("Unknown variant")
    end)
end)

describe("Tagged validation", function(): ()
    it("throws on empty tagField", function(): ()
        expect(function(): ()
            Lync.tagged("", { a = Lync.nothing })
        end):toThrow("must not be empty")
    end)
    it("throws on empty variants", function(): ()
        expect(function(): ()
            Lync.tagged("type", {})
        end):toThrow("at least one variant")
    end)
end)

return nil
