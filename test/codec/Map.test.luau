--!strict
--!optimize 2
local Baseline = require(script.Parent.Parent.Parent.internal.Baseline)
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe("map", function(): ()
    it("empty", function(): ()
        local c = Lync.map(Lync.string, Lync.u8)
        local r = roundTrip(c, {})
        local count = 0
        for _ in r do
            count += 1
        end
        expect(count):toBe(0)
    end)
    it("string keys", function(): ()
        local c = Lync.map(Lync.string, Lync.u8)
        local r = roundTrip(c, { hp = 100, mp = 50 })
        expect(r.hp):toBe(100)
        expect(r.mp):toBe(50)
    end)
    it("numeric keys", function(): ()
        local c = Lync.map(Lync.u8, Lync.string)
        local r = roundTrip(c, { [1] = "one", [2] = "two" })
        expect(r[1]):toBe("one")
        expect(r[2]):toBe("two")
    end)
end)

describe("map maxCount", function(): ()
    it("rejects over limit", function(): ()
        expect(function(): ()
            local c = Lync.map(Lync.string, Lync.u8, 1)
            local ch = Channel.create()
            c.write(ch, { a = 1, b = 2 })
            local buf = buffer.create(ch.cursor)
            buffer.copy(buf, 0, ch.buff, 0, ch.cursor)
            c.read(buf, 0, nil)
        end):toThrow("exceeds max")
    end)
end)

describe("deltaMap", function(): ()
    it("full round-trip", function(): ()
        Baseline.setReadKey(false)
        local c = Lync.deltaMap(Lync.string, Lync.u8)
        local r = roundTrip(c, { a = 1, b = 2 })
        expect(r.a):toBe(1)
        expect(r.b):toBe(2)
    end)
    it("identical write is smaller", function(): ()
        Baseline.setReadKey(false)
        local c = Lync.deltaMap(Lync.string, Lync.u8)
        local ch = Channel.create()
        c.write(ch, { a = 1, b = 2 })
        local w1 = ch.cursor
        ch.cursor = 0
        c.write(ch, { a = 1, b = 2 })
        expect(ch.cursor):toBeLessThan(w1)
    end)
    it("numeric keys full round-trip", function(): ()
        Baseline.setReadKey(false)
        local c = Lync.deltaMap(Lync.u16, Lync.string)
        local r = roundTrip(c, { [1] = "one", [2] = "two", [300] = "three hundred" })
        expect(r[1]):toBe("one")
        expect(r[2]):toBe("two")
        expect(r[300]):toBe("three hundred")
    end)
    it("numeric keys unchanged is smaller", function(): ()
        Baseline.setReadKey(false)
        local c = Lync.deltaMap(Lync.u16, Lync.string)
        local ch = Channel.create()
        c.write(ch, { [1] = "one", [2] = "two" })
        local fullSize = ch.cursor
        ch.cursor = 0
        c.write(ch, { [1] = "one", [2] = "two" })
        expect(ch.cursor):toBeLessThan(fullSize)
    end)
    it("numeric keys upsert and remove", function(): ()
        Baseline.setReadKey(false)
        local c = Lync.deltaMap(Lync.u16, Lync.u8)
        local ch = Channel.create()

        -- First write: full frame
        c.write(ch, { [10] = 100, [20] = 200 })
        local buf1 = buffer.create(ch.cursor)
        buffer.copy(buf1, 0, ch.buff, 0, ch.cursor)
        local r1 = c.read(buf1, 0, nil)
        expect(r1[10]):toBe(100)
        expect(r1[20]):toBe(200)

        -- Second write: remove key 20, add key 30, change key 10
        ch.cursor = 0
        c.write(ch, { [10] = 50, [30] = 150 })
        local buf2 = buffer.create(ch.cursor)
        buffer.copy(buf2, 0, ch.buff, 0, ch.cursor)
        local r2 = c.read(buf2, 0, nil)
        expect(r2[10]):toBe(50)
        expect(r2[30]):toBe(150)
        expect(r2[20]):toBe(nil)
    end)
end)

return nil
