--!strict
--!optimize 2
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe("tagged", function(): ()
    local c = Lync.tagged("type", {
        damage = Lync.struct({ amount = Lync.int(0, 255) }),
        heal   = Lync.struct({ amount = Lync.int(0, 255), source = Lync.string }),
    })
    it("damage variant", function(): ()
        local r = roundTrip(c, { type = "damage", amount = 50 })
        expect(r.type):toBe("damage"); expect(r.amount):toBe(50)
    end)
    it("heal variant", function(): ()
        local r = roundTrip(c, { type = "heal", amount = 30, source = "potion" })
        expect(r.type):toBe("heal"); expect(r.amount):toBe(30); expect(r.source):toBe("potion")
    end)
    it("variant tag = u8 (1 byte overhead)", function(): ()
        local simple = Lync.tagged("t", { a = Lync.struct({ v = Lync.int(0, 255) }) })
        local _, w = roundTrip(simple, { t = "a", v = 42 })
        expect(w):toBe(2) -- 1 tag + 1 u8
    end)
    it("unknown variant errors on write", function(): ()
        expect(function(): () c.write(Channel.create(), { type = "nope" }) end):toThrow("unknown variant")
    end)
    it("missing tag field errors", function(): ()
        expect(function(): () c.write(Channel.create(), { amount = 10 }) end):toThrow("missing tagField")
    end)
    it("single variant", function(): ()
        local s = Lync.tagged("kind", { only = Lync.struct({ x = Lync.int(0, 255) }) })
        local r = roundTrip(s, { kind = "only", x = 7 })
        expect(r.kind):toBe("only"); expect(r.x):toBe(7)
    end)
end)

describe("tagged define-time errors", function(): ()
    it("empty tagField", function(): () expect(function(): () Lync.tagged("", { a = Lync.bool }) end):toThrow("empty") end)
    it("no variants", function(): () expect(function(): () Lync.tagged("t", {}) end):toThrow("at least one") end)
end)

return nil
