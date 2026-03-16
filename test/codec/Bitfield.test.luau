--!strict
--!optimize 2
local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe ("Bitfield booleans only", function (): ()
    local codec = Lync.bitfield ({
        alive = { type = "bool" },
        visible = { type = "bool" },
        grounded = { type = "bool" },
    })
    it ("all true", function (): ()
        local r = roundTrip (codec, { alive = true, visible = true, grounded = true })
        expect (r.alive):toBe (true)
        expect (r.visible):toBe (true)
        expect (r.grounded):toBe (true)
    end)
    it ("all false", function (): ()
        local r = roundTrip (codec, { alive = false, visible = false, grounded = false })
        expect (r.alive):toBe (false)
        expect (r.visible):toBe (false)
        expect (r.grounded):toBe (false)
    end)
    it ("mixed", function (): ()
        local r = roundTrip (codec, { alive = true, visible = false, grounded = true })
        expect (r.alive):toBe (true)
        expect (r.visible):toBe (false)
        expect (r.grounded):toBe (true)
    end)
    it ("1 byte", function (): ()
        local _, w = roundTrip (codec, { alive = true, visible = true, grounded = true })
        expect (w):toBe (1)
    end)
    it ("_size is 1", function (): ()
        expect ((codec :: any)._size):toBe (1)
    end)
end)

describe ("Bitfield 9 bools (needs 2 bytes)", function (): ()
    local schema = {}
    for i = 1, 9 do
        schema["b" .. i] = { type = "bool" }
    end
    local codec = Lync.bitfield (schema)
    it ("_size is 2", function (): ()
        expect ((codec :: any)._size):toBe (2)
    end)
    it ("round-trips all true", function (): ()
        local input = {}
        for i = 1, 9 do
            input["b" .. i] = true
        end
        local r = roundTrip (codec, input)
        for i = 1, 9 do
            expect (r["b" .. i]):toBe (true)
        end
    end)
    it ("round-trips alternating", function (): ()
        local input = {}
        for i = 1, 9 do
            input["b" .. i] = i % 2 == 0
        end
        local r = roundTrip (codec, input)
        for i = 1, 9 do
            expect (r["b" .. i]):toBe (i % 2 == 0)
        end
    end)
end)

describe ("Bitfield mixed bools+uints", function (): ()
    local codec = Lync.bitfield ({
        active = { type = "bool" },
        level = { type = "uint", width = 5 },
        team = { type = "uint", width = 2 },
    })
    it ("round-trips mixed", function (): ()
        local r = roundTrip (codec, { active = true, level = 31, team = 3 })
        expect (r.active):toBe (true)
        expect (r.level):toBe (31)
        expect (r.team):toBe (3)
    end)
    it ("round-trips zeros", function (): ()
        local r = roundTrip (codec, { active = false, level = 0, team = 0 })
        expect (r.active):toBe (false)
        expect (r.level):toBe (0)
        expect (r.team):toBe (0)
    end)
    it ("_size 1 for 8 bits", function (): ()
        expect ((codec :: any)._size):toBe (1)
    end)
end)

describe ("Bitfield 16-bit", function (): ()
    local codec =
        Lync.bitfield ({ a = { type = "uint", width = 8 }, b = { type = "uint", width = 4 } })
    it ("round-trips 12 bits", function (): ()
        local r = roundTrip (codec, { a = 255, b = 15 })
        expect (r.a):toBe (255)
        expect (r.b):toBe (15)
    end)
    it ("_size is 2", function (): ()
        expect ((codec :: any)._size):toBe (2)
    end)
end)

describe ("Bitfield 32-bit", function (): ()
    local codec = Lync.bitfield ({
        big = { type = "uint", width = 20 },
        small = { type = "uint", width = 4 },
    })
    it ("round-trips 24 bits", function (): ()
        local r = roundTrip (codec, { big = 1048575, small = 15 })
        expect (r.big):toBe (1048575)
        expect (r.small):toBe (15)
    end)
    it ("_size is 4", function (): ()
        expect ((codec :: any)._size):toBe (4)
    end)
end)

describe ("Bitfield mask overflow", function (): ()
    local codec = Lync.bitfield ({ val = { type = "uint", width = 3 } })
    it ("masks 255 to 7 (3 bits)", function (): ()
        expect (roundTrip (codec, { val = 255 }).val):toBe (7)
    end)
    it ("masks 8 to 0", function (): ()
        expect (roundTrip (codec, { val = 8 }).val):toBe (0)
    end)
end)

describe ("Bitfield width-1 uint", function (): ()
    local codec = Lync.bitfield ({ flag = { type = "uint", width = 1 } })
    it ("round-trips 0", function (): ()
        expect (roundTrip (codec, { flag = 0 }).flag):toBe (0)
    end)
    it ("round-trips 1", function (): ()
        expect (roundTrip (codec, { flag = 1 }).flag):toBe (1)
    end)
    it ("masks 2 to 0", function (): ()
        expect (roundTrip (codec, { flag = 2 }).flag):toBe (0)
    end)
end)

describe ("Bitfield validation", function (): ()
    it ("throws on empty", function (): ()
        expect (function (): ()
            Lync.bitfield ({})
        end):toThrow ("at least one field")
    end)
    it ("throws no width", function (): ()
        expect (function (): ()
            Lync.bitfield ({ s = { type = "uint" } })
        end):toThrow ("requires a width")
    end)
    it ("throws >32 bits", function (): ()
        expect (function (): ()
            Lync.bitfield ({ a = { type = "uint", width = 20 }, b = { type = "uint", width = 20 } })
        end):toThrow ("exceeds 32 bits")
    end)
    it ("throws width 0", function (): ()
        expect (function (): ()
            Lync.bitfield ({ s = { type = "uint", width = 0 } })
        end):toThrow ("width must be")
    end)
    it ("throws width 33", function (): ()
        expect (function (): ()
            Lync.bitfield ({ s = { type = "uint", width = 33 } })
        end):toThrow ("width must be")
    end)
    it ("throws int no width", function (): ()
        expect (function (): ()
            Lync.bitfield ({ s = { type = "int" } })
        end):toThrow ("requires a width")
    end)
end)

describe ("Bitfield signed int basics", function (): ()
    local codec = Lync.bitfield ({
        offset = { type = "int", width = 5 },
    })
    it ("positive value", function (): ()
        expect (roundTrip (codec, { offset = 15 }).offset):toBe (15)
    end)
    it ("zero", function (): ()
        expect (roundTrip (codec, { offset = 0 }).offset):toBe (0)
    end)
    it ("negative value", function (): ()
        expect (roundTrip (codec, { offset = -1 }).offset):toBe (-1)
    end)
    it ("min value (-16 for 5 bits)", function (): ()
        expect (roundTrip (codec, { offset = -16 }).offset):toBe (-16)
    end)
    it ("max value (15 for 5 bits)", function (): ()
        expect (roundTrip (codec, { offset = 15 }).offset):toBe (15)
    end)
    it ("_size is 1", function (): ()
        expect ((codec :: any)._size):toBe (1)
    end)
end)

describe ("Bitfield signed int 3-bit", function (): ()
    local codec = Lync.bitfield ({
        val = { type = "int", width = 3 },
    })
    it ("-4 (min)", function (): ()
        expect (roundTrip (codec, { val = -4 }).val):toBe (-4)
    end)
    it ("3 (max)", function (): ()
        expect (roundTrip (codec, { val = 3 }).val):toBe (3)
    end)
    it ("-1", function (): ()
        expect (roundTrip (codec, { val = -1 }).val):toBe (-1)
    end)
    it ("0", function (): ()
        expect (roundTrip (codec, { val = 0 }).val):toBe (0)
    end)
    it ("1", function (): ()
        expect (roundTrip (codec, { val = 1 }).val):toBe (1)
    end)
end)

describe ("Bitfield signed 1-bit", function (): ()
    local codec = Lync.bitfield ({
        sign = { type = "int", width = 1 },
    })
    it ("0", function (): ()
        expect (roundTrip (codec, { sign = 0 }).sign):toBe (0)
    end)
    it ("-1", function (): ()
        expect (roundTrip (codec, { sign = -1 }).sign):toBe (-1)
    end)
end)

describe ("Bitfield mixed bool+uint+int", function (): ()
    local codec = Lync.bitfield ({
        alive = { type = "bool" },
        level = { type = "uint", width = 5 },
        delta = { type = "int", width = 4 },
    })
    it ("round-trips all types", function (): ()
        local r = roundTrip (codec, { alive = true, level = 31, delta = -8 })
        expect (r.alive):toBe (true)
        expect (r.level):toBe (31)
        expect (r.delta):toBe (-8)
    end)
    it ("zeros", function (): ()
        local r = roundTrip (codec, { alive = false, level = 0, delta = 0 })
        expect (r.alive):toBe (false)
        expect (r.level):toBe (0)
        expect (r.delta):toBe (0)
    end)
    it ("negative delta with max level", function (): ()
        local r = roundTrip (codec, { alive = true, level = 31, delta = -1 })
        expect (r.alive):toBe (true)
        expect (r.level):toBe (31)
        expect (r.delta):toBe (-1)
    end)
    it ("_size is 2 (10 bits)", function (): ()
        expect ((codec :: any)._size):toBe (2)
    end)
end)

describe ("Bitfield uint-only schema has no sign overhead", function (): ()
    local codec = Lync.bitfield ({
        a = { type = "uint", width = 4 },
        b = { type = "bool" },
    })
    it ("round-trips normally", function (): ()
        local r = roundTrip (codec, { a = 15, b = true })
        expect (r.a):toBe (15)
        expect (r.b):toBe (true)
    end)
end)

return nil
