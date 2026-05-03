--!strict
--!optimize 2
-- Delta codec wire behavior across struct, array, map.

local Env = require(script:FindFirstAncestor("test").Env)

local Channel = Env.Internal.Channel
local Lync = Env.Lync
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("integration.DeltaCodecs", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("deltaStruct wire", function(): ()
        it("first write produces a real payload", function(): ()
            local c = Lync.deltaStruct({ x = Lync.int(0, 255) })
            local ch = Channel.create()
            c.write(ch, { x = 1 })
            expect(ch.cursor):toBeGreaterThan(1)
        end)
        it("identical second write collapses to 1 byte", function(): ()
            local c = Lync.deltaStruct({ hp = Lync.int(0, 255), mp = Lync.int(0, 255) })
            local ch = Channel.create()
            c.write(ch, { hp = 100, mp = 50 })
            ch.cursor = 0
            c.write(ch, { hp = 100, mp = 50 })
            expect(ch.cursor):toBe(1)
        end)
        it("three identical writes all collapse", function(): ()
            local c = Lync.deltaStruct({ v = Lync.int(0, 255) })
            local ch = Channel.create()
            c.write(ch, { v = 42 })
            for _ = 1, 3 do
                ch.cursor = 0
                c.write(ch, { v = 42 })
                expect(ch.cursor):toBe(1)
            end
        end)
        it("change then unchanged returns to 1 byte", function(): ()
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

    describe("deltaArray wire", function(): ()
        it("unchanged = 1 byte", function(): ()
            local c = Lync.deltaArray(Lync.int(0, 255))
            local ch = Channel.create()
            c.write(ch, { 10, 20 })
            ch.cursor = 0
            c.write(ch, { 10, 20 })
            expect(ch.cursor):toBe(1)
        end)
        it("single element changed > 1 byte", function(): ()
            local c = Lync.deltaArray(Lync.int(0, 255))
            local ch = Channel.create()
            c.write(ch, { 10, 20 })
            ch.cursor = 0
            c.write(ch, { 10, 99 })
            expect(ch.cursor):toBeGreaterThan(1)
        end)
    end)

    describe("deltaMap wire", function(): ()
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

    describe("delta + unreliable rejected at packet definition", function(): ()
        it("deltaStruct over unreliable throws at define time", function(): ()
            expect(function(): ()
                Lync.packet(
                    "delta_unrel_pkt",
                    Lync.deltaStruct({ x = Lync.int(0, 255) }),
                    { unreliable = true }
                )
            end):toThrow("delta")
        end)
    end)
end)

return nil
