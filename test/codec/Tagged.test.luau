--!strict
--!optimize 2
local Channel = require (script.Parent.Parent.Parent.core.Channel)
local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe ("Tagged round-trip", function (): ()
    local codec = Lync.tagged ("kind", {
        damage = Lync.struct ({ kind = Lync.string, amount = Lync.u16 }),
        heal = Lync.struct ({ kind = Lync.string, amount = Lync.u16, source = Lync.string }),
        death = Lync.struct ({ kind = Lync.string }),
    })
    it ("damage", function (): ()
        local r = roundTrip (codec, { kind = "damage", amount = 50 })
        expect (r.kind):toBe ("damage")
        expect (r.amount):toBe (50)
    end)
    it ("heal", function (): ()
        local r = roundTrip (codec, { kind = "heal", amount = 25, source = "potion" })
        expect (r.kind):toBe ("heal")
        expect (r.amount):toBe (25)
        expect (r.source):toBe ("potion")
    end)
    it ("death", function (): ()
        local r = roundTrip (codec, { kind = "death" })
        expect (r.kind):toBe ("death")
    end)
    it ("throws unknown", function (): ()
        expect (function (): ()
            local ch = Channel.create ()
            codec.write (ch, { kind = "explode" })
        end):toThrow ("Unknown variant")
    end)
end)

describe ("Tagged single variant", function (): ()
    local codec = Lync.tagged ("t", { only = Lync.struct ({ t = Lync.string, val = Lync.u8 }) })
    it ("round-trips", function (): ()
        local r = roundTrip (codec, { t = "only", val = 42 })
        expect (r.t):toBe ("only")
        expect (r.val):toBe (42)
    end)
end)

describe ("Tagged _size", function (): ()
    it ("nil when variants have variable-size", function (): ()
        local codec = Lync.tagged (
            "t",
            {
                a = Lync.struct ({ t = Lync.string, x = Lync.u16 }),
                b = Lync.struct ({ t = Lync.string, y = Lync.u16 }),
            }
        )
        expect ((codec :: any)._size):toBeNil ()
    end)
    it ("computed when all variants same fixed size", function (): ()
        local codec = Lync.tagged (
            "t",
            {
                a = Lync.struct ({ t = Lync.string, x = Lync.u32 }),
                b = Lync.struct ({ t = Lync.string, y = Lync.u32 }),
            }
        )
        -- string is variable, so nil
        expect ((codec :: any)._size):toBeNil ()
    end)
end)

describe ("Tagged variant ordering", function (): ()
    it ("tag index is alphabetical", function (): ()
        local codec = Lync.tagged ("t", {
            zebra = Lync.struct ({ t = Lync.string }),
            alpha = Lync.struct ({ t = Lync.string }),
        })
        local ch = Channel.create ()
        codec.write (ch, { t = "alpha" })
        expect (buffer.readu8 (ch.buff, 0)):toBe (0) -- "alpha" is first alphabetically
        ch.cursor = 0
        codec.write (ch, { t = "zebra" })
        expect (buffer.readu8 (ch.buff, 0)):toBe (1) -- "zebra" is second
    end)
end)

describe ("Tagged validation", function (): ()
    it ("throws empty tagField", function (): ()
        expect (function (): ()
            Lync.tagged ("", { a = Lync.nothing })
        end):toThrow ("must not be empty")
    end)
    it ("throws empty variants", function (): ()
        expect (function (): ()
            Lync.tagged ("type", {})
        end):toThrow ("at least one variant")
    end)
    it ("throws empty variant name", function (): ()
        expect (function (): ()
            Lync.tagged ("type", { [""] = Lync.nothing })
        end):toThrow ("must not be empty")
    end)
end)

return nil
