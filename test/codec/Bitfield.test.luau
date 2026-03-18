--!strict
--!optimize 2
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe("bitfield", function(): ()
    it("single flag", function(): ()
        local c = Lync.bitfield({ isAlive = { type = "bool" } })
        local r = roundTrip(c, { isAlive = true })
        expect(r.isAlive):toBe(true)
    end)
    it("multiple flags", function(): ()
        local c = Lync.bitfield({
            a = { type = "bool" },
            b = { type = "bool" },
            c = { type = "bool" },
            d = { type = "bool" },
        })
        local r = roundTrip(c, { a = true, b = false, c = true, d = false })
        expect(r.a):toBe(true)
        expect(r.b):toBe(false)
        expect(r.c):toBe(true)
        expect(r.d):toBe(false)
    end)
    it("8 flags = 1 byte", function(): ()
        local fields = {}
        for i = 1, 8 do
            fields["b" .. i] = { type = "bool" }
        end
        local c = Lync.bitfield(fields)
        local data = {}
        for i = 1, 8 do
            data["b" .. i] = true
        end
        local _, w = roundTrip(c, data)
        expect(w):toBe(1)
    end)
    it("9 flags = 2 bytes", function(): ()
        local fields = {}
        for i = 1, 9 do
            fields["b" .. i] = { type = "bool" }
        end
        local c = Lync.bitfield(fields)
        local data = {}
        for i = 1, 9 do
            data["b" .. i] = true
        end
        local _, w = roundTrip(c, data)
        expect(w):toBe(2)
    end)
    it("all false", function(): ()
        local c =
            Lync.bitfield({ a = { type = "bool" }, b = { type = "bool" }, c = { type = "bool" } })
        local r = roundTrip(c, { a = false, b = false, c = false })
        expect(r.a):toBe(false)
        expect(r.b):toBe(false)
        expect(r.c):toBe(false)
    end)
end)

return nil
