--!strict
--!optimize 2
-- Lync.bitfield: sub-byte packing of bool / uint / int fields.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.meta.Bitfield", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("bool fields", function(): ()
        it("single bool packs into 1 byte", function(): ()
            local c = Lync.bitfield({ flag = { type = "bool" } })
            local r, w = Channel.roundTripStrict(c, { flag = true })
            expect(r.flag):toBe(true)
            expect(w):toBe(1)
        end)
        it("3 bools pack into 1 byte", function(): ()
            local c = Lync.bitfield({
                a = { type = "bool" },
                b = { type = "bool" },
                c = { type = "bool" },
            })
            local r, w = Channel.roundTripStrict(c, { a = true, b = false, c = true })
            expect(r.a):toBe(true)
            expect(r.b):toBe(false)
            expect(r.c):toBe(true)
            expect(w):toBe(1)
        end)
    end)

    describe("uint fields", function(): ()
        it("uint width 5 round-trips up to 31", function(): ()
            local c = Lync.bitfield({ level = { type = "uint", width = 5 } })
            expect(Channel.roundTripStrict(c, { level = 31 }).level):toBe(31)
            expect(Channel.roundTripStrict(c, { level = 0 }).level):toBe(0)
        end)
        it("uint width 8 max value", function(): ()
            local c = Lync.bitfield({ val = { type = "uint", width = 8 } })
            expect(Channel.roundTripStrict(c, { val = 255 }).val):toBe(255)
        end)
    end)

    describe("int fields (sign-extended)", function(): ()
        it("positive value round-trips", function(): ()
            expect(
                Channel.roundTripStrict(
                    Lync.bitfield({ d = { type = "int", width = 4 } }),
                    { d = 7 }
                ).d
            ):toBe(7)
        end)
        it("negative value round-trips", function(): ()
            expect(
                Channel.roundTripStrict(
                    Lync.bitfield({ d = { type = "int", width = 4 } }),
                    { d = -5 }
                ).d
            ):toBe(-5)
        end)
        it("zero", function(): ()
            expect(
                Channel.roundTripStrict(
                    Lync.bitfield({ d = { type = "int", width = 4 } }),
                    { d = 0 }
                ).d
            ):toBe(0)
        end)
        it("min value -8 (4-bit signed)", function(): ()
            expect(
                Channel.roundTripStrict(
                    Lync.bitfield({ d = { type = "int", width = 4 } }),
                    { d = -8 }
                ).d
            ):toBe(-8)
        end)
    end)

    describe("mixed fields", function(): ()
        it("bool + uint + int = 12 bits = 2 bytes", function(): ()
            local c = Lync.bitfield({
                alive = { type = "bool" },
                hp = { type = "uint", width = 7 },
                dir = { type = "int", width = 4 },
            })
            local r, w = Channel.roundTripStrict(c, { alive = true, hp = 100, dir = -3 })
            expect(r.alive):toBe(true)
            expect(r.hp):toBe(100)
            expect(r.dir):toBe(-3)
            expect(w):toBe(2)
        end)
    end)

    describe("byte-width selection", function(): ()
        it("8 bits = 1 byte", function(): ()
            local c = Lync.bitfield({
                a = { type = "uint", width = 4 },
                b = { type = "uint", width = 4 },
            })
            local _, w = Channel.roundTripStrict(c, { a = 15, b = 15 })
            expect(w):toBe(1)
        end)
        it("9 bits = 2 bytes", function(): ()
            local c = Lync.bitfield({
                a = { type = "uint", width = 5 },
                b = { type = "uint", width = 4 },
            })
            local _, w = Channel.roundTripStrict(c, { a = 31, b = 15 })
            expect(w):toBe(2)
        end)
        it("16 bits = 2 bytes", function(): ()
            local c = Lync.bitfield({
                a = { type = "uint", width = 8 },
                b = { type = "uint", width = 8 },
            })
            local _, w = Channel.roundTripStrict(c, { a = 255, b = 128 })
            expect(w):toBe(2)
        end)
        it("17 bits promotes to 4 bytes", function(): ()
            local c = Lync.bitfield({
                a = { type = "uint", width = 9 },
                b = { type = "uint", width = 8 },
            })
            local _, w = Channel.roundTripStrict(c, { a = 511, b = 128 })
            expect(w):toBe(4)
        end)
        it("32 bits exactly = 4 bytes", function(): ()
            local c = Lync.bitfield({
                a = { type = "uint", width = 16 },
                b = { type = "uint", width = 16 },
            })
            local r, w = Channel.roundTripStrict(c, { a = 65535, b = 32768 })
            expect(r.a):toBe(65535)
            expect(r.b):toBe(32768)
            expect(w):toBe(4)
        end)
    end)

    describe("define-time errors", function(): ()
        it("> 32 total bits throws", function(): ()
            expect(function(): ()
                Lync.bitfield({
                    a = { type = "uint", width = 20 },
                    b = { type = "uint", width = 20 },
                })
            end):toThrow("exceeds 32")
        end)
        it("empty schema throws", function(): ()
            expect(function(): ()
                Lync.bitfield({})
            end):toThrow("at least one")
        end)
        it("unknown field type throws", function(): ()
            expect(function(): ()
                Lync.bitfield({ x = { type = "float", width = 8 } } :: any)
            end):toThrow("unknown type")
        end)
        it("uint width 0 throws", function(): ()
            expect(function(): ()
                Lync.bitfield({ x = { type = "uint", width = 0 } })
            end):toThrow("width")
        end)
        it("int width 1 throws (sign bit needed)", function(): ()
            expect(function(): ()
                Lync.bitfield({ x = { type = "int", width = 1 } })
            end):toThrow("width")
        end)
    end)

    describe("write-time range validation (no silent truncation)", function(): ()
        -- Pre-fix `band(value, mask)` silently truncated out-of-range values;
        -- the round-trip shipped a corrupted value with no warning.
        it("uint value above width range throws", function(): ()
            local c = Lync.bitfield({ x = { type = "uint", width = 4 } })
            expect(function(): ()
                Channel.encode(c, { x = 100 }) -- max is 15
            end):toThrow("uint range")
        end)
        it("uint value below 0 throws", function(): ()
            local c = Lync.bitfield({ x = { type = "uint", width = 4 } })
            expect(function(): ()
                Channel.encode(c, { x = -1 })
            end):toThrow("uint range")
        end)
        it("uint non-integer throws", function(): ()
            local c = Lync.bitfield({ x = { type = "uint", width = 4 } })
            expect(function(): ()
                Channel.encode(c, { x = 1.5 })
            end):toThrow("uint range")
        end)
        it("int value above max throws", function(): ()
            local c = Lync.bitfield({ x = { type = "int", width = 4 } }) -- range [-8, 7]
            expect(function(): ()
                Channel.encode(c, { x = 8 })
            end):toThrow("int range")
        end)
        it("int value below min throws", function(): ()
            local c = Lync.bitfield({ x = { type = "int", width = 4 } })
            expect(function(): ()
                Channel.encode(c, { x = -9 })
            end):toThrow("int range")
        end)
        it("uint at exact upper bound round-trips", function(): ()
            local c = Lync.bitfield({ x = { type = "uint", width = 4 } })
            local r = Channel.roundTripStrict(c, { x = 15 })
            expect(r.x):toBe(15)
        end)
        it("int at exact bounds round-trips", function(): ()
            local c = Lync.bitfield({ x = { type = "int", width = 4 } })
            local rHi = Channel.roundTripStrict(c, { x = 7 })
            expect(rHi.x):toBe(7)
            local rLo = Channel.roundTripStrict(c, { x = -8 })
            expect(rLo.x):toBe(-8)
        end)
    end)
end)

return nil
