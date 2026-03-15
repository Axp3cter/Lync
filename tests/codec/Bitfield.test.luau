--!strict
--!optimize 2
-- Bitfield.test.luau — Round-trip tests for bit-level packing codec.

local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)

local describe = Runner.describe
local it = Runner.it
local expect = Runner.expect
local roundTrip = Runner.roundTrip

-- Tests ------------------------------------------------------------------

describe ("Bitfield booleans only", function (): ()
    local codec = Lync.bitfield ({
        alive = { type = "bool" },
        visible = { type = "bool" },
        grounded = { type = "bool" },
    })

    it ("round-trips all true", function (): ()
        local result = roundTrip (codec, { alive = true, visible = true, grounded = true })
        expect (result.alive):toBe (true)
        expect (result.visible):toBe (true)
        expect (result.grounded):toBe (true)
    end)
    it ("round-trips all false", function (): ()
        local result = roundTrip (codec, { alive = false, visible = false, grounded = false })
        expect (result.alive):toBe (false)
        expect (result.visible):toBe (false)
        expect (result.grounded):toBe (false)
    end)
    it ("round-trips mixed values", function (): ()
        local result = roundTrip (codec, { alive = true, visible = false, grounded = true })
        expect (result.alive):toBe (true)
        expect (result.visible):toBe (false)
        expect (result.grounded):toBe (true)
    end)
    it ("packs 3 bools into 1 byte", function (): ()
        local _, written, _ = roundTrip (codec, { alive = true, visible = true, grounded = true })
        expect (written):toBe (1)
    end)
end)

describe ("Bitfield mixed bools and uints", function (): ()
    local codec = Lync.bitfield ({
        active = { type = "bool" },
        level = { type = "uint", width = 5 },
        team = { type = "uint", width = 2 },
    })

    it ("round-trips mixed values", function (): ()
        local result = roundTrip (codec, { active = true, level = 31, team = 3 })
        expect (result.active):toBe (true)
        expect (result.level):toBe (31)
        expect (result.team):toBe (3)
    end)
    it ("round-trips zeros", function (): ()
        local result = roundTrip (codec, { active = false, level = 0, team = 0 })
        expect (result.active):toBe (false)
        expect (result.level):toBe (0)
        expect (result.team):toBe (0)
    end)
    it ("packs 8 bits into 1 byte", function (): ()
        local _, written, _ = roundTrip (codec, { active = true, level = 1, team = 1 })
        expect (written):toBe (1)
    end)
end)

describe ("Bitfield validation", function (): ()
    it ("throws on empty schema", function (): ()
        expect (function (): ()
            Lync.bitfield ({})
        end):toThrow ("at least one field")
    end)
    it ("throws on uint without width", function (): ()
        expect (function (): ()
            Lync.bitfield ({ score = { type = "uint" } })
        end):toThrow ("requires a width")
    end)
end)

return nil
