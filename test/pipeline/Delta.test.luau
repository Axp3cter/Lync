--!strict
--!optimize 2
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe("deltaStruct wire behavior", function(): ()
    it("unchanged = exactly 1 byte", function(): ()
        local c = Lync.deltaStruct({ hp = Lync.int(0, 255), mp = Lync.int(0, 255) })
        local ch = Channel.create()
        c.write(ch, { hp = 100, mp = 50 })
        ch.cursor = 0
        c.write(ch, { hp = 100, mp = 50 })
        expect(ch.cursor):toBe(1)
    end)
    it("first write is always > 1 byte", function(): ()
        local c = Lync.deltaStruct({ x = Lync.int(0, 255) })
        local ch = Channel.create()
        c.write(ch, { x = 1 })
        expect(ch.cursor):toBeGreaterThan(1)
    end)
    it("changed triggers re-send", function(): ()
        local c = Lync.deltaStruct({ x = Lync.int(0, 255) })
        local ch = Channel.create()
        c.write(ch, { x = 1 })
        ch.cursor = 0
        c.write(ch, { x = 2 })
        expect(ch.cursor):toBeGreaterThan(1)
    end)
    it("three unchanged cycles all 1 byte", function(): ()
        local c = Lync.deltaStruct({ v = Lync.int(0, 255) })
        local ch = Channel.create()
        c.write(ch, { v = 42 })
        for _ = 1, 3 do
            ch.cursor = 0
            c.write(ch, { v = 42 })
            expect(ch.cursor):toBe(1)
        end
    end)
    it("change then unchanged = 1 byte again", function(): ()
        local c = Lync.deltaStruct({ v = Lync.int(0, 255) })
        local ch = Channel.create()
        c.write(ch, { v = 1 })
        ch.cursor = 0
        c.write(ch, { v = 2 })
        ch.cursor = 0
        c.write(ch, { v = 2 })
        expect(ch.cursor):toBe(1)
    end)
end)

describe("deltaArray wire behavior", function(): ()
    it("unchanged = 1 byte", function(): ()
        local c = Lync.deltaArray(Lync.int(0, 255))
        local ch = Channel.create()
        c.write(ch, { 10, 20 })
        ch.cursor = 0
        c.write(ch, { 10, 20 })
        expect(ch.cursor):toBe(1)
    end)
    it("changed > 1 byte", function(): ()
        local c = Lync.deltaArray(Lync.int(0, 255))
        local ch = Channel.create()
        c.write(ch, { 10, 20 })
        ch.cursor = 0
        c.write(ch, { 10, 99 })
        expect(ch.cursor):toBeGreaterThan(1)
    end)
end)

describe("deltaMap wire behavior", function(): ()
    it("unchanged = 1 byte", function(): ()
        local c = Lync.deltaMap(Lync.string, Lync.int(0, 255))
        local ch = Channel.create()
        c.write(ch, { a = 1 })
        ch.cursor = 0
        c.write(ch, { a = 1 })
        expect(ch.cursor):toBe(1)
    end)
    it("changed > 1 byte", function(): ()
        local c = Lync.deltaMap(Lync.string, Lync.int(0, 255))
        local ch = Channel.create()
        c.write(ch, { a = 1 })
        ch.cursor = 0
        c.write(ch, { a = 2 })
        expect(ch.cursor):toBeGreaterThan(1)
    end)
end)

describe("delta + unreliable", function(): ()
    it("deltaStruct errors at define time", function(): ()
        expect(function(): ()
            Lync.packet(
                "__d_unrel_s",
                Lync.deltaStruct({ x = Lync.int(0, 255) }),
                { unreliable = true }
            )
        end):toThrow("delta")
    end)
end)

return nil
