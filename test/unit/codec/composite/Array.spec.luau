--!strict
--!optimize 2
-- Lync.array: bool-pack / direct / generic dispatch and deltaArray.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.composite.Array", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("metadata", function(): ()
        it("flags _isArray", function(): ()
            expect((Lync.array(Lync.int(0, 255)) :: any)._isArray):toBe(true)
        end)
        it("records element codec", function(): ()
            local elem = Lync.int(0, 255)
            local c = Lync.array(elem)
            expect((c :: any)._element):toBe(elem)
        end)
        it("records maxCount", function(): ()
            local c = Lync.array(Lync.int(0, 255), 100)
            expect((c :: any)._maxCount):toBe(100)
        end)
    end)

    describe("basic round-trip (generic + direct paths)", function(): ()
        it("empty array = 1 byte (varint count)", function(): ()
            local r, w = Channel.roundTripStrict(Lync.array(Lync.int(0, 255)), {})
            expect(#r):toBe(0)
            expect(w):toBe(1)
        end)
        it("3 u8 values", function(): ()
            local r = Channel.roundTripStrict(Lync.array(Lync.int(0, 255)), { 10, 20, 30 })
            expect(r[1]):toBe(10)
            expect(r[2]):toBe(20)
            expect(r[3]):toBe(30)
        end)
        it("50 u8 values", function(): ()
            local data = table.create(50)
            for i = 1, 50 do
                data[i] = i
            end
            local r = Channel.roundTripStrict(Lync.array(Lync.int(0, 255)), data)
            expect(r[1]):toBe(1)
            expect(r[25]):toBe(25)
            expect(r[50]):toBe(50)
        end)
        it("string elements (generic path)", function(): ()
            local r = Channel.roundTripStrict(Lync.array(Lync.string), { "hello", "world", "foo" })
            expect(r[1]):toBe("hello")
            expect(r[3]):toBe("foo")
        end)
        it("struct elements (direct path)", function(): ()
            local elem = Lync.struct({ x = Lync.int(0, 255), y = Lync.int(0, 255) })
            local r =
                Channel.roundTripStrict(Lync.array(elem), { { x = 1, y = 2 }, { x = 3, y = 4 } })
            expect(r[1].x):toBe(1)
            expect(r[2].y):toBe(4)
        end)
        it("nested arrays", function(): ()
            local inner = Lync.array(Lync.int(0, 255))
            local r = Channel.roundTripStrict(Lync.array(inner), { { 1, 2 }, { 3, 4, 5 } })
            expect(r[1][1]):toBe(1)
            expect(r[1][2]):toBe(2)
            expect(r[2][3]):toBe(5)
        end)
    end)

    describe("bool element bit-packing", function(): ()
        it("8 bools fit in 2 bytes (1 count + 1 packed)", function(): ()
            local input = { true, false, true, true, false, false, true, false }
            local r, w = Channel.roundTripStrict(Lync.array(Lync.bool), input)
            expect(w):toBe(2)
            expect(r[1]):toBe(true)
            expect(r[2]):toBe(false)
            expect(r[7]):toBe(true)
        end)
        it("9 bools spill to 3 bytes", function(): ()
            local input = table.create(9)
            for i = 1, 9 do
                input[i] = i % 2 == 0
            end
            local _, w = Channel.roundTripStrict(Lync.array(Lync.bool), input)
            expect(w):toBe(3)
        end)
        it("16 bools = 3 bytes (1 count + 2 packed)", function(): ()
            local input = table.create(16)
            for i = 1, 16 do
                input[i] = i % 3 == 0
            end
            local r, w = Channel.roundTripStrict(Lync.array(Lync.bool), input)
            expect(w):toBe(3)
            expect(r[3]):toBe(true)
            expect(r[4]):toBe(false)
        end)
        it("empty bool array = 1 byte", function(): ()
            local r, w = Channel.roundTripStrict(Lync.array(Lync.bool), {})
            expect(#r):toBe(0)
            expect(w):toBe(1)
        end)
        it("single bool", function(): ()
            local r = Channel.roundTripStrict(Lync.array(Lync.bool), { true })
            expect(r[1]):toBe(true)
        end)
    end)

    describe("direct path (fixed-size element)", function(): ()
        it("u16 array", function(): ()
            local r = Channel.roundTripStrict(Lync.array(Lync.int(0, 65535)), { 1000, 2000, 3000 })
            expect(r[1]):toBe(1000)
            expect(r[3]):toBe(3000)
        end)
        it("f32 array", function(): ()
            local r = Channel.roundTripStrict(Lync.array(Lync.f32), { 1.5, 2.5 })
            expect(r[1]):toBeCloseTo(1.5)
            expect(r[2]):toBeCloseTo(2.5)
        end)
    end)

    describe("maxCount enforcement", function(): ()
        it("read of an over-limit array throws", function(): ()
            local r = Channel.encode(Lync.array(Lync.int(0, 255)), { 1, 2, 3, 4, 5 })
            local bounded = Lync.array(Lync.int(0, 255), 3)
            expect(function(): ()
                bounded.read(r.buffer, 0, nil)
            end):toThrow("exceeds max")
        end)
        it("read within limit succeeds", function(): ()
            local r = Channel.roundTripStrict(Lync.array(Lync.int(0, 255), 5), { 1, 2, 3 })
            expect(#r):toBe(3)
        end)
    end)

    describe("deltaArray metadata", function(): ()
        it("flags _isDelta", function(): ()
            expect((Lync.deltaArray(Lync.int(0, 255)) :: any)._isDelta):toBe(true)
        end)
        it("flags _isArray", function(): ()
            expect((Lync.deltaArray(Lync.int(0, 255)) :: any)._isArray):toBe(true)
        end)
        it("records element codec and maxCount", function(): ()
            local elem = Lync.int(0, 255)
            local c = Lync.deltaArray(elem, 50) :: any
            expect(c._element):toBe(elem)
            expect(c._maxCount):toBe(50)
        end)
    end)

    describe("deltaArray UNCHANGED", function(): ()
        local function newCh(): any
            return Env.Internal.Channel.create()
        end

        it("identical second write = 1 byte", function(): ()
            local c = Lync.deltaArray(Lync.int(0, 255))
            local ch = newCh()
            c.write(ch, { 10, 20, 30 })
            ch.cursor = 0
            c.write(ch, { 10, 20, 30 })
            expect(ch.cursor):toBe(1)
        end)
        it("identical empty arrays = 1 byte each frame", function(): ()
            local c = Lync.deltaArray(Lync.int(0, 255))
            local ch = newCh()
            c.write(ch, {})
            ch.cursor = 0
            c.write(ch, {})
            expect(ch.cursor):toBe(1)
        end)
        it("repeated identical writes stay at 1 byte", function(): ()
            local c = Lync.deltaArray(Lync.int(0, 65535))
            local ch = newCh()
            c.write(ch, { 1, 2, 3, 4, 5 })
            for _ = 1, 10 do
                ch.cursor = 0
                c.write(ch, { 1, 2, 3, 4, 5 })
                expect(ch.cursor):toBe(1)
            end
        end)
    end)

    describe("deltaArray PATCH", function(): ()
        local function newCh(): any
            return Env.Internal.Channel.create()
        end

        it("single mid-array change uses PATCH (saves vs FULL)", function(): ()
            local c = Lync.deltaArray(Lync.int(0, 255), nil)
            local ch = newCh()
            c.write(ch, { 10, 20, 30, 40, 50 })
            ch.cursor = 0
            c.write(ch, { 10, 20, 99, 40, 50 })
            -- PATCH: 1 flag + 1 (newLen=5) + 1 (changeCount=1) + 1 (idx=3) + 1 (val=99) = 5
            -- FULL would be: 1 flag + 1 (count=5) + 5 elems = 7
            expect(ch.cursor):toBe(5)
        end)
        it("appended index emits as a change", function(): ()
            local c = Lync.deltaArray(Lync.int(0, 255))
            local ch = newCh()
            c.write(ch, { 10, 20 })
            ch.cursor = 0
            c.write(ch, { 10, 20, 30 })
            -- PATCH: 1 + 1 (newLen=3) + 1 (changeCount=1) + 1 (idx=3) + 1 (val=30) = 5
            expect(ch.cursor):toBe(5)
        end)
        it("truncated array emits PATCH with 0 changes", function(): ()
            local c = Lync.deltaArray(Lync.int(0, 255))
            local ch = newCh()
            c.write(ch, { 10, 20, 30 })
            ch.cursor = 0
            c.write(ch, { 10, 20 })
            -- PATCH: 1 + 1 (newLen=2) + 1 (changeCount=0) = 3
            expect(ch.cursor):toBe(3)
        end)
    end)

    describe("deltaArray FULL fallback", function(): ()
        local function newCh(): any
            return Env.Internal.Channel.create()
        end

        it("changing every element falls back to FULL", function(): ()
            local c = Lync.deltaArray(Lync.int(0, 255))
            local ch = newCh()
            c.write(ch, { 1, 2, 3, 4 })
            ch.cursor = 0
            c.write(ch, { 11, 22, 33, 44 })
            -- changeCount=4, len=4, 4*2 >= 4 → FULL.
            -- FULL: 1 flag + 1 (count=4) + 4 elems = 6
            expect(ch.cursor):toBe(6)
        end)
        it("first frame emits FULL", function(): ()
            local c = Lync.deltaArray(Lync.int(0, 255))
            local ch = newCh()
            c.write(ch, { 10, 20, 30 })
            -- FULL: 1 flag + 1 count + 3 elems = 5
            expect(ch.cursor):toBe(5)
        end)
    end)

    describe("deltaArray round-trip via Baseline", function(): ()
        local Baseline = Env.Internal.Baseline
        local function decode(c: any, ch: any, startCursor: number): any
            local payload = buffer.create(ch.cursor - startCursor)
            buffer.copy(payload, 0, ch.buff, startCursor, ch.cursor - startCursor)
            local v = c.read(payload, 0, nil)
            return v
        end

        it("FULL → PATCH → UNCHANGED sequence decodes to correct arrays", function(): ()
            local c = Lync.deltaArray(Lync.int(0, 255))
            local ch = Env.Internal.Channel.create()

            local s1 = ch.cursor
            c.write(ch, { 1, 2, 3 })
            local v1 = decode(c, ch, s1)
            expect(v1[1]):toBe(1)
            expect(v1[2]):toBe(2)
            expect(v1[3]):toBe(3)

            local s2 = ch.cursor
            c.write(ch, { 1, 99, 3 })
            local v2 = decode(c, ch, s2)
            expect(v2[1]):toBe(1)
            expect(v2[2]):toBe(99)
            expect(v2[3]):toBe(3)

            local s3 = ch.cursor
            c.write(ch, { 1, 99, 3 })
            local v3 = decode(c, ch, s3)
            expect(v3[1]):toBe(1)
            expect(v3[2]):toBe(99)
            expect(v3[3]):toBe(3)
        end)
        it("array growth then truncation decodes correctly", function(): ()
            Baseline.reset()
            local c = Lync.deltaArray(Lync.int(0, 255))
            local ch = Env.Internal.Channel.create()

            local s1 = ch.cursor
            c.write(ch, { 1, 2 })
            decode(c, ch, s1)

            local s2 = ch.cursor
            c.write(ch, { 1, 2, 3, 4 })
            local v2 = decode(c, ch, s2)
            expect(#v2):toBe(4)
            expect(v2[3]):toBe(3)
            expect(v2[4]):toBe(4)

            local s3 = ch.cursor
            c.write(ch, { 1, 2 })
            local v3 = decode(c, ch, s3)
            expect(#v3):toBe(2)
        end)
    end)

    describe("deltaArray maxCount enforcement", function(): ()
        it("write rejects oversized arrays", function(): ()
            local c = Lync.deltaArray(Lync.int(0, 255), 3)
            local ch = Env.Internal.Channel.create()
            expect(function(): ()
                c.write(ch, { 1, 2, 3, 4 })
            end):toThrow("exceeds max")
        end)
    end)
end)

return nil
