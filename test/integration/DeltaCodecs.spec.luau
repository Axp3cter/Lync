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
        it("deltaArray over unreliable throws at define time", function(): ()
            expect(function(): ()
                Lync.packet(
                    "delta_arr_unrel_pkt",
                    Lync.deltaArray(Lync.int(0, 255)),
                    { unreliable = true }
                )
            end):toThrow("delta")
        end)
        it("deltaMap over unreliable throws at define time", function(): ()
            expect(function(): ()
                Lync.packet(
                    "delta_map_unrel_pkt",
                    Lync.deltaMap(Lync.string, Lync.int(0, 255)),
                    { unreliable = true }
                )
            end):toThrow("delta")
        end)
    end)

    describe("deltaArray PATCH wire", function(): ()
        it("changes < len/2 use PATCH (smaller than FULL)", function(): ()
            local c = Lync.deltaArray(Lync.int(0, 255))
            local ch = Channel.create()
            c.write(ch, { 1, 2, 3, 4, 5, 6, 7, 8 })
            ch.cursor = 0
            c.write(ch, { 1, 2, 99, 4, 5, 6, 7, 8 })
            -- PATCH: 1 + 1 + 1 + 1 + 1 = 5; FULL would be 1 + 1 + 8 = 10
            expect(ch.cursor):toBe(5)
        end)
        it("changes >= len/2 fall back to FULL", function(): ()
            local c = Lync.deltaArray(Lync.int(0, 255))
            local ch = Channel.create()
            c.write(ch, { 1, 2, 3, 4 })
            ch.cursor = 0
            c.write(ch, { 11, 22, 33, 44 })
            -- FULL: 1 + 1 + 4 = 6
            expect(ch.cursor):toBe(6)
        end)
        it("growth-only is PATCH with appended indices", function(): ()
            local c = Lync.deltaArray(Lync.int(0, 255))
            local ch = Channel.create()
            c.write(ch, { 10, 20 })
            ch.cursor = 0
            c.write(ch, { 10, 20, 30 })
            -- PATCH: 1 + 1 (newLen=3) + 1 (cnt=1) + 1 (idx=3) + 1 (val=30) = 5
            expect(ch.cursor):toBe(5)
        end)
        it("truncation-only is PATCH with newLen smaller", function(): ()
            local c = Lync.deltaArray(Lync.int(0, 255))
            local ch = Channel.create()
            c.write(ch, { 10, 20, 30 })
            ch.cursor = 0
            c.write(ch, { 10, 20 })
            -- PATCH: 1 + 1 (newLen=2) + 1 (cnt=0) = 3
            expect(ch.cursor):toBe(3)
        end)
    end)

    describe("deltaMap DIFF wire", function(): ()
        it("single value change emits DIFF", function(): ()
            local c = Lync.deltaMap(Lync.string, Lync.int(0, 255))
            local ch = Channel.create()
            c.write(ch, { hp = 100, mp = 50 })
            ch.cursor = 0
            c.write(ch, { hp = 80, mp = 50 })
            expect(ch.cursor):toBeGreaterThan(1)
        end)
        it("removed key emits a remove entry", function(): ()
            local c = Lync.deltaMap(Lync.string, Lync.int(0, 255))
            local ch = Channel.create()
            c.write(ch, { a = 1, b = 2 })
            ch.cursor = 0
            c.write(ch, { a = 1 })
            expect(ch.cursor):toBeGreaterThan(1)
        end)
        it("added key emits a change entry", function(): ()
            local c = Lync.deltaMap(Lync.string, Lync.int(0, 255))
            local ch = Channel.create()
            c.write(ch, { a = 1 })
            ch.cursor = 0
            c.write(ch, { a = 1, b = 2 })
            expect(ch.cursor):toBeGreaterThan(1)
        end)
    end)

    describe("delta scalars", function(): ()
        it("deltaInt unchanged: 1 byte", function(): ()
            local c = Lync.deltaInt(0, 1000)
            local ch = Channel.create()
            c.write(ch, 100)
            ch.cursor = 0
            c.write(ch, 100)
            expect(ch.cursor):toBe(1)
        end)
        it("deltaVec3 unchanged: 3 bytes (one zigzag(0) per axis)", function(): ()
            local c = Lync.deltaVec3(0, 100, 0.01)
            local ch = Channel.create()
            c.write(ch, Vector3.new(50, 50, 50))
            ch.cursor = 0
            c.write(ch, Vector3.new(50, 50, 50))
            expect(ch.cursor):toBe(3)
        end)
        it("deltaCFrame unchanged: 1 byte (header with no flags)", function(): ()
            local c = Lync.deltaCFrame(-1000, 1000, 0.01)
            local ch = Channel.create()
            c.write(ch, CFrame.new(0, 0, 0))
            ch.cursor = 0
            c.write(ch, CFrame.new(0, 0, 0))
            expect(ch.cursor):toBe(1)
        end)
    end)

    describe("_hasDelta propagation", function(): ()
        it("struct with deltaInt field flags _hasDelta", function(): ()
            local s = Lync.struct({ x = Lync.deltaInt(0, 100) })
            expect((s :: any)._hasDelta):toBe(true)
        end)
        it("struct with no delta children does NOT flag _hasDelta", function(): ()
            local s = Lync.struct({ x = Lync.int(0, 100) })
            expect((s :: any)._hasDelta):toBeNil()
        end)
        it("array of deltaInt flags _hasDelta", function(): ()
            local a = Lync.array(Lync.deltaInt(0, 100))
            expect((a :: any)._hasDelta):toBe(true)
        end)
        it("optional of deltaInt flags _hasDelta", function(): ()
            local o = Lync.optional(Lync.deltaInt(0, 100))
            expect((o :: any)._hasDelta):toBe(true)
        end)
        it("tuple containing deltaInt flags _hasDelta", function(): ()
            local t = Lync.tuple(Lync.int(0, 100), Lync.deltaInt(0, 100))
            expect((t :: any)._hasDelta):toBe(true)
        end)
        it("tagged variant containing delta flags _hasDelta", function(): ()
            local v = Lync.tagged("kind", {
                a = Lync.struct({ x = Lync.int(0, 100) }),
                b = Lync.struct({ y = Lync.deltaInt(0, 100) }),
            })
            expect((v :: any)._hasDelta):toBe(true)
        end)
    end)
end)

return nil
