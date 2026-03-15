--!strict
--!optimize 2
local Baseline = require (script.Parent.Parent.Parent.core.Baseline)
local Channel = require (script.Parent.Parent.Parent.core.Channel)
local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

-- struct -----------------------------------------------------------------

describe ("struct basics", function (): ()
    local codec = Lync.struct ({ health = Lync.u16, name = Lync.string, alive = Lync.bool })
    it ("round-trips values", function (): ()
        local r = roundTrip (codec, { health = 100, name = "Alice", alive = true })
        expect (r.health):toBe (100)
        expect (r.name):toBe ("Alice")
        expect (r.alive):toBe (true)
    end)
    it ("round-trips zeros", function (): ()
        local r = roundTrip (codec, { health = 0, name = "", alive = false })
        expect (r.health):toBe (0)
        expect (r.name):toBe ("")
        expect (r.alive):toBe (false)
    end)
    it ("consumed == written", function (): ()
        local _, w, c = roundTrip (codec, { health = 50, name = "hi", alive = true })
        expect (c):toBe (w)
    end)
end)

describe ("struct bools packing", function (): ()
    it ("3 bools = 1 byte", function (): ()
        local codec = Lync.struct ({ a = Lync.bool, b = Lync.bool, c = Lync.bool })
        local _, w = roundTrip (codec, { a = true, b = false, c = true })
        expect (w):toBe (1)
    end)
    it ("8 bools = 1 byte", function (): ()
        local schema = {}
        for i = 1, 8 do
            schema["b" .. i] = Lync.bool
        end
        local codec = Lync.struct (schema)
        local _, w = roundTrip (
            codec,
            {
                b1 = true,
                b2 = false,
                b3 = true,
                b4 = false,
                b5 = true,
                b6 = false,
                b7 = true,
                b8 = false,
            }
        )
        expect (w):toBe (1)
    end)
    it ("9 bools = 2 bytes", function (): ()
        local schema = {}
        for i = 1, 9 do
            schema["b" .. i] = Lync.bool
        end
        local codec = Lync.struct (schema)
        local input = {}
        for i = 1, 9 do
            input["b" .. i] = i % 2 == 0
        end
        local r, w = roundTrip (codec, input)
        expect (w):toBe (2)
        for i = 1, 9 do
            expect (r["b" .. i]):toBe (i % 2 == 0)
        end
    end)
    it ("bools-only _size", function (): ()
        local codec = Lync.struct ({ a = Lync.bool, b = Lync.bool, c = Lync.bool })
        expect ((codec :: any)._size):toBe (1)
    end)
end)

describe ("struct _size", function (): ()
    it ("all fixed = known", function (): ()
        expect ((Lync.struct ({ x = Lync.f32, y = Lync.f32 }) :: any)._size):toBe (8)
    end)
    it ("has variable = nil", function (): ()
        expect ((Lync.struct ({ x = Lync.f32, n = Lync.string }) :: any)._size):toBeNil ()
    end)
    it ("mixed fixed + bool", function (): ()
        expect ((Lync.struct ({ x = Lync.u8, ok = Lync.bool }) :: any)._size):toBe (2)
    end)
end)

describe ("struct nested", function (): ()
    local inner = Lync.struct ({ x = Lync.f32, y = Lync.f32 })
    local outer = Lync.struct ({ pos = inner, label = Lync.string })
    it ("round-trips", function (): ()
        local r = roundTrip (outer, { pos = { x = 1.5, y = 2.5 }, label = "spawn" })
        expect (r.pos.x):toBeCloseTo (1.5)
        expect (r.pos.y):toBeCloseTo (2.5)
        expect (r.label):toBe ("spawn")
    end)
end)

describe ("struct many fields", function (): ()
    local schema = {}
    for i = 1, 20 do
        schema["f" .. i] = Lync.u8
    end
    local codec = Lync.struct (schema)
    it ("round-trips 20 u8 fields", function (): ()
        local input = {}
        for i = 1, 20 do
            input["f" .. i] = i
        end
        local r = roundTrip (codec, input)
        for i = 1, 20 do
            expect (r["f" .. i]):toBe (i)
        end
    end)
end)

describe ("struct validation", function (): ()
    it ("throws on empty schema", function (): ()
        expect (function (): ()
            Lync.struct ({})
        end):toThrow ("at least one field")
    end)
end)

-- deltaStruct ------------------------------------------------------------

describe ("deltaStruct lifecycle", function (): ()
    local codec = Lync.deltaStruct ({ hp = Lync.u16, mp = Lync.u16, alive = Lync.bool })
    it ("_isDelta is true", function (): ()
        expect ((codec :: any)._isDelta):toBe (true)
    end)

    it ("first write = FLAG_FULL", function (): ()
        local ch = Channel.create ()
        codec.write (ch, { hp = 100, mp = 50, alive = true })
        expect (buffer.readu8 (ch.buff, 0)):toBe (1)
    end)
    it ("unchanged = FLAG_UNCHANGED (1 byte)", function (): ()
        local ch = Channel.create ()
        codec.write (ch, { hp = 100, mp = 50, alive = true })
        local pos = ch.cursor
        codec.write (ch, { hp = 100, mp = 50, alive = true })
        expect (ch.cursor - pos):toBe (1)
        expect (buffer.readu8 (ch.buff, pos)):toBe (2)
    end)
    it ("partial change = FLAG_DELTA", function (): ()
        local ch = Channel.create ()
        codec.write (ch, { hp = 100, mp = 50, alive = true })
        local pos = ch.cursor
        codec.write (ch, { hp = 80, mp = 50, alive = true })
        expect (buffer.readu8 (ch.buff, pos)):toBe (0)
        expect (ch.cursor - pos < pos):toBe (true)
    end)
    it ("full change = delta with all fields dirty", function (): ()
        local ch = Channel.create ()
        codec.write (ch, { hp = 100, mp = 50, alive = true })
        local pos = ch.cursor
        codec.write (ch, { hp = 0, mp = 0, alive = false })
        expect (buffer.readu8 (ch.buff, pos)):toBe (0)
    end)
end)

describe ("deltaStruct read fidelity", function (): ()
    local codec = Lync.deltaStruct ({ hp = Lync.u16, mp = Lync.u16, alive = Lync.bool })

    it ("multi-step cycle preserves all data", function (): ()
        Baseline.setReadKey ("__ds_fidelity")
        local ch = Channel.create ()

        -- Full
        codec.write (ch, { hp = 100, mp = 50, alive = true })
        local b1 = buffer.create (ch.cursor)
        buffer.copy (b1, 0, ch.buff, 0, ch.cursor)
        local r1 = codec.read (b1, 0, nil)
        expect (r1.hp):toBe (100)
        expect (r1.mp):toBe (50)
        expect (r1.alive):toBe (true)

        -- Unchanged
        local p2 = ch.cursor
        codec.write (ch, { hp = 100, mp = 50, alive = true })
        local b2 = buffer.create (ch.cursor - p2)
        buffer.copy (b2, 0, ch.buff, p2, ch.cursor - p2)
        local r2 = codec.read (b2, 0, nil)
        expect (r2.hp):toBe (100)
        expect (r2.mp):toBe (50)
        expect (r2.alive):toBe (true)

        -- Delta (change hp only)
        local p3 = ch.cursor
        codec.write (ch, { hp = 80, mp = 50, alive = true })
        local b3 = buffer.create (ch.cursor - p3)
        buffer.copy (b3, 0, ch.buff, p3, ch.cursor - p3)
        local r3 = codec.read (b3, 0, nil)
        expect (r3.hp):toBe (80)
        expect (r3.mp):toBe (50)
        expect (r3.alive):toBe (true)

        -- Change everything
        local p4 = ch.cursor
        codec.write (ch, { hp = 0, mp = 999, alive = false })
        local b4 = buffer.create (ch.cursor - p4)
        buffer.copy (b4, 0, ch.buff, p4, ch.cursor - p4)
        local r4 = codec.read (b4, 0, nil)
        expect (r4.hp):toBe (0)
        expect (r4.mp):toBe (999)
        expect (r4.alive):toBe (false)

        Baseline.clearSource ("__ds_fidelity")
    end)
end)

describe ("deltaStruct validation", function (): ()
    it ("throws on empty", function (): ()
        expect (function (): ()
            Lync.deltaStruct ({})
        end):toThrow ("at least one field")
    end)
end)

-- deltaArray -------------------------------------------------------------

describe ("deltaArray lifecycle", function (): ()
    local codec = Lync.deltaArray (Lync.u16)
    it ("_isDelta is true", function (): ()
        expect ((codec :: any)._isDelta):toBe (true)
    end)
    it ("first = FLAG_FULL", function (): ()
        local ch = Channel.create ()
        codec.write (ch, { 10, 20, 30 })
        expect (buffer.readu8 (ch.buff, 0)):toBe (1)
    end)
    it ("unchanged = FLAG_UNCHANGED", function (): ()
        local ch = Channel.create ()
        codec.write (ch, { 10, 20, 30 })
        local pos = ch.cursor
        codec.write (ch, { 10, 20, 30 })
        expect (ch.cursor - pos):toBe (1)
        expect (buffer.readu8 (ch.buff, pos)):toBe (2)
    end)
    it ("element change = FLAG_DELTA", function (): ()
        local ch = Channel.create ()
        codec.write (ch, { 10, 20, 30 })
        local pos = ch.cursor
        codec.write (ch, { 10, 99, 30 })
        expect (buffer.readu8 (ch.buff, pos)):toBe (0)
    end)
    it ("length change = FLAG_FULL again", function (): ()
        local ch = Channel.create ()
        codec.write (ch, { 10, 20 })
        local pos = ch.cursor
        codec.write (ch, { 10, 20, 30 })
        expect (buffer.readu8 (ch.buff, pos)):toBe (1)
    end)
end)

describe ("deltaArray read fidelity", function (): ()
    local codec = Lync.deltaArray (Lync.u16)
    it ("multi-step", function (): ()
        Baseline.setReadKey ("__da_fidelity")
        local ch = Channel.create ()
        -- Full
        codec.write (ch, { 10, 20, 30 })
        local b1 = buffer.create (ch.cursor)
        buffer.copy (b1, 0, ch.buff, 0, ch.cursor)
        local r1 = codec.read (b1, 0, nil)
        expect (r1[1]):toBe (10)
        expect (r1[2]):toBe (20)
        expect (r1[3]):toBe (30)
        -- Unchanged
        local p2 = ch.cursor
        codec.write (ch, { 10, 20, 30 })
        local b2 = buffer.create (ch.cursor - p2)
        buffer.copy (b2, 0, ch.buff, p2, ch.cursor - p2)
        local r2 = codec.read (b2, 0, nil)
        expect (r2[1]):toBe (10)
        expect (r2[3]):toBe (30)
        -- Change middle
        local p3 = ch.cursor
        codec.write (ch, { 10, 99, 30 })
        local b3 = buffer.create (ch.cursor - p3)
        buffer.copy (b3, 0, ch.buff, p3, ch.cursor - p3)
        local r3 = codec.read (b3, 0, nil)
        expect (r3[2]):toBe (99)
        -- Length change
        local p4 = ch.cursor
        codec.write (ch, { 1, 2 })
        local b4 = buffer.create (ch.cursor - p4)
        buffer.copy (b4, 0, ch.buff, p4, ch.cursor - p4)
        local r4 = codec.read (b4, 0, nil)
        expect (#r4):toBe (2)
        expect (r4[1]):toBe (1)
        expect (r4[2]):toBe (2)
        Baseline.clearSource ("__da_fidelity")
    end)
end)

-- array ------------------------------------------------------------------

describe ("array", function (): ()
    local codec = Lync.array (Lync.u16)
    it ("empty", function (): ()
        expect (#roundTrip (codec, {})):toBe (0)
    end)
    it ("single", function (): ()
        local r = roundTrip (codec, { 999 })
        expect (#r):toBe (1)
        expect (r[1]):toBe (999)
    end)
    it ("five", function (): ()
        local r = roundTrip (codec, { 10, 20, 30, 40, 50 })
        expect (#r):toBe (5)
        expect (r[1]):toBe (10)
        expect (r[5]):toBe (50)
    end)
    it ("100 elements", function (): ()
        local inp = table.create (100)
        for i = 1, 100 do
            inp[i] = i
        end
        local r = roundTrip (codec, inp)
        expect (#r):toBe (100)
        expect (r[1]):toBe (1)
        expect (r[100]):toBe (100)
    end)
    it ("of structs", function (): ()
        local sc = Lync.array (Lync.struct ({ id = Lync.u32, tag = Lync.string }))
        local r = roundTrip (sc, { { id = 1, tag = "a" }, { id = 2, tag = "b" } })
        expect (#r):toBe (2)
        expect (r[1].id):toBe (1)
        expect (r[2].tag):toBe ("b")
    end)
end)

-- map --------------------------------------------------------------------

describe ("map", function (): ()
    local codec = Lync.map (Lync.string, Lync.u32)
    it ("empty", function (): ()
        local r = roundTrip (codec, {})
        local n = 0
        for _ in r do
            n += 1
        end
        expect (n):toBe (0)
    end)
    it ("single", function (): ()
        expect (roundTrip (codec, { key = 42 }).key):toBe (42)
    end)
    it ("multiple", function (): ()
        local r = roundTrip (codec, { gold = 100, silver = 50 })
        expect (r.gold):toBe (100)
        expect (r.silver):toBe (50)
    end)
    it ("numeric keys", function (): ()
        local mc = Lync.map (Lync.u8, Lync.string)
        local r = roundTrip (mc, { [1] = "a", [2] = "b" })
        expect (r[1]):toBe ("a")
        expect (r[2]):toBe ("b")
    end)
end)

-- optional ---------------------------------------------------------------

describe ("optional", function (): ()
    local codec = Lync.optional (Lync.u32)
    it ("nil round-trips", function (): ()
        expect (roundTrip (codec, nil)):toBeNil ()
    end)
    it ("value round-trips", function (): ()
        expect (roundTrip (codec, 42)):toBe (42)
    end)
    it ("nil = 1 byte", function (): ()
        local _, w = roundTrip (codec, nil)
        expect (w):toBe (1)
    end)
    it ("present = 5 bytes", function (): ()
        local _, w = roundTrip (codec, 42)
        expect (w):toBe (5)
    end)
    it ("0 is present", function (): ()
        expect (roundTrip (codec, 0)):toBe (0)
    end)
    it ("optional string nil", function (): ()
        local sc = Lync.optional (Lync.string)
        expect (roundTrip (sc, nil)):toBeNil ()
    end)
    it ("optional string present", function (): ()
        local sc = Lync.optional (Lync.string)
        expect (roundTrip (sc, "hi")):toBe ("hi")
    end)
end)

return nil
