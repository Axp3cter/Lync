--!strict
--!optimize 2
local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe ("tagged", function (): ()
    it ("variant A", function (): ()
        local c = Lync.tagged (
            "type",
            {
                Move = Lync.struct ({ x = Lync.f32, y = Lync.f32 }),
                Chat = Lync.struct ({ msg = Lync.string }),
            }
        )
        local r = roundTrip (c, { type = "Move", x = 1.5, y = 2.5 })
        expect (r.type):toBe ("Move")
        expect (r.x):toBeCloseTo (1.5)
    end)
    it ("variant B", function (): ()
        local c = Lync.tagged (
            "type",
            {
                Move = Lync.struct ({ x = Lync.f32, y = Lync.f32 }),
                Chat = Lync.struct ({ msg = Lync.string }),
            }
        )
        local r = roundTrip (c, { type = "Chat", msg = "hi" })
        expect (r.type):toBe ("Chat")
        expect (r.msg):toBe ("hi")
    end)
    it ("throws unknown variant", function (): ()
        local c = Lync.tagged ("type", { A = Lync.struct ({ v = Lync.u8 }) })
        expect (function (): ()
            local Channel = require (script.Parent.Parent.Parent.internal.Channel)
            local ch = Channel.create ()
            c.write (ch, { type = "B", v = 1 })
        end):toThrow ()
    end)
end)

describe ("tagged with bools", function (): ()
    it ("variant with bool fields", function (): ()
        local c = Lync.tagged ("type", {
            State = Lync.struct ({ alive = Lync.bool, hp = Lync.u8 }),
            Name = Lync.struct ({ value = Lync.string }),
        })
        local r = roundTrip (c, { type = "State", alive = true, hp = 50 })
        expect (r.type):toBe ("State")
        expect (r.alive):toBe (true)
        expect (r.hp):toBe (50)
    end)
end)

return nil
