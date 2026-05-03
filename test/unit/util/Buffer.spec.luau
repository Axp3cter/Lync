--!strict
--!optimize 2
-- util.Buffer: rangeEqual, snapshot, xorApply.

local Env = require(script:FindFirstAncestor("test").Env)

local Sandbox = Env.Sandbox

local Buf = require(script:FindFirstAncestor("Lync").util.Buffer)

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

local function fill(b: buffer, bytes: { number }): ()
    for i, v in bytes do
        buffer.writeu8(b, i - 1, v)
    end
end

local function readBytes(b: buffer, len: number): { number }
    local out = table.create(len)
    for i = 0, len - 1 do
        out[i + 1] = buffer.readu8(b, i)
    end
    return out
end

describe("util.Buffer", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("rangeEqual: identical content", function(): ()
        it("zero-length range is equal", function(): ()
            local a = buffer.create(4)
            local b = buffer.create(4)
            expect(Buf.rangeEqual(a, 0, b, 0, 0)):toBe(true)
        end)
        it("matches single byte at offset 0", function(): ()
            local a = buffer.create(1)
            buffer.writeu8(a, 0, 0xAB)
            local b = buffer.create(1)
            buffer.writeu8(b, 0, 0xAB)
            expect(Buf.rangeEqual(a, 0, b, 0, 1)):toBe(true)
        end)
        it("matches 7 bytes (sub-aligned)", function(): ()
            local a = buffer.create(8)
            fill(a, { 1, 2, 3, 4, 5, 6, 7, 0 })
            local b = buffer.create(8)
            fill(b, { 1, 2, 3, 4, 5, 6, 7, 0 })
            expect(Buf.rangeEqual(a, 0, b, 0, 7)):toBe(true)
        end)
        it("matches 8 bytes (one aligned8 step)", function(): ()
            local a = buffer.create(8)
            fill(a, { 1, 2, 3, 4, 5, 6, 7, 8 })
            local b = buffer.create(8)
            fill(b, { 1, 2, 3, 4, 5, 6, 7, 8 })
            expect(Buf.rangeEqual(a, 0, b, 0, 8)):toBe(true)
        end)
        it("matches 13 bytes (one aligned8 + one u32 + one u8 tail)", function(): ()
            local a = buffer.create(13)
            for i = 0, 12 do
                buffer.writeu8(a, i, i + 1)
            end
            local b = buffer.create(13)
            for i = 0, 12 do
                buffer.writeu8(b, i, i + 1)
            end
            expect(Buf.rangeEqual(a, 0, b, 0, 13)):toBe(true)
        end)
        it("matches 64 bytes (eight aligned8 steps)", function(): ()
            local a = buffer.create(64)
            for i = 0, 63 do
                buffer.writeu8(a, i, i)
            end
            local b = buffer.create(64)
            for i = 0, 63 do
                buffer.writeu8(b, i, i)
            end
            expect(Buf.rangeEqual(a, 0, b, 0, 64)):toBe(true)
        end)
    end)

    describe("rangeEqual: divergent content", function(): ()
        it("differs at first byte", function(): ()
            local a = buffer.create(8)
            fill(a, { 0, 0, 0, 0, 0, 0, 0, 0 })
            local b = buffer.create(8)
            fill(b, { 1, 0, 0, 0, 0, 0, 0, 0 })
            expect(Buf.rangeEqual(a, 0, b, 0, 8)):toBe(false)
        end)
        it("differs at the aligned8 boundary", function(): ()
            local a = buffer.create(8)
            fill(a, { 0, 0, 0, 0, 0, 0, 0, 0 })
            local b = buffer.create(8)
            fill(b, { 0, 0, 0, 0, 0, 0, 0, 1 })
            expect(Buf.rangeEqual(a, 0, b, 0, 8)):toBe(false)
        end)
        it("differs in the u32-step region (byte 9)", function(): ()
            local a = buffer.create(12)
            for i = 0, 11 do
                buffer.writeu8(a, i, 0)
            end
            local b = buffer.create(12)
            for i = 0, 11 do
                buffer.writeu8(b, i, 0)
            end
            buffer.writeu8(b, 9, 1)
            expect(Buf.rangeEqual(a, 0, b, 0, 12)):toBe(false)
        end)
        it("differs in the byte-tail region", function(): ()
            local a = buffer.create(13)
            for i = 0, 12 do
                buffer.writeu8(a, i, 0)
            end
            local b = buffer.create(13)
            for i = 0, 12 do
                buffer.writeu8(b, i, 0)
            end
            buffer.writeu8(b, 12, 1)
            expect(Buf.rangeEqual(a, 0, b, 0, 13)):toBe(false)
        end)
    end)

    describe("rangeEqual: offsets", function(): ()
        it("compares disjoint regions of the same buffer", function(): ()
            local b = buffer.create(8)
            fill(b, { 1, 2, 3, 4, 1, 2, 3, 4 })
            expect(Buf.rangeEqual(b, 0, b, 4, 4)):toBe(true)
        end)
        it("non-zero offset on either side", function(): ()
            local a = buffer.create(8)
            fill(a, { 0, 0, 1, 2, 3, 4, 0, 0 })
            local b = buffer.create(8)
            fill(b, { 1, 2, 3, 4, 0, 0, 0, 0 })
            expect(Buf.rangeEqual(a, 2, b, 0, 4)):toBe(true)
        end)
    end)

    describe("snapshot", function(): ()
        it("zero-length yields a fresh empty buffer", function(): ()
            local out = Buf.snapshot(buffer.create(8), 0)
            expect(buffer.len(out)):toBe(0)
        end)
        it("copies the requested prefix exactly", function(): ()
            local src = buffer.create(8)
            fill(src, { 1, 2, 3, 4, 5, 6, 7, 8 })
            local out = Buf.snapshot(src, 5)
            expect(buffer.len(out)):toBe(5)
            expect(readBytes(out, 5)):toEqual({ 1, 2, 3, 4, 5 })
        end)
        it("returns a distinct buffer (not aliasing the source)", function(): ()
            local src = buffer.create(4)
            fill(src, { 9, 9, 9, 9 })
            local out = Buf.snapshot(src, 4)
            buffer.writeu8(out, 0, 0)
            expect(buffer.readu8(src, 0)):toBe(9)
        end)
        it("snapshot then mutate source does not affect snapshot", function(): ()
            local src = buffer.create(4)
            fill(src, { 1, 2, 3, 4 })
            local out = Buf.snapshot(src, 4)
            buffer.writeu8(src, 0, 0xFF)
            expect(buffer.readu8(out, 0)):toBe(1)
        end)
    end)

    describe("xorApply: no previous", function(): ()
        it("returns the current buffer unchanged when previous is nil", function(): ()
            local cur = buffer.create(4)
            fill(cur, { 1, 2, 3, 4 })
            local out = Buf.xorApply(cur, 4, nil, nil)
            expect(out):toBe(cur)
        end)
    end)

    describe("xorApply: same length", function(): ()
        it("identical buffers XOR to all zeros", function(): ()
            local cur = buffer.create(8)
            fill(cur, { 1, 2, 3, 4, 5, 6, 7, 8 })
            local prev = buffer.create(8)
            fill(prev, { 1, 2, 3, 4, 5, 6, 7, 8 })
            local out = Buf.xorApply(cur, 8, prev, 8)
            expect(readBytes(out, 8)):toEqual({ 0, 0, 0, 0, 0, 0, 0, 0 })
        end)
        it("XOR is symmetric (a ^ b == b ^ a)", function(): ()
            local a = buffer.create(8)
            fill(a, { 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22 })
            local b = buffer.create(8)
            fill(b, { 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0 })
            local ab = Buf.xorApply(a, 8, b, 8)
            local ba = Buf.xorApply(b, 8, a, 8)
            expect(readBytes(ab, 8)):toEqual(readBytes(ba, 8))
        end)
        it("XORing twice returns the original (a ^ b ^ b == a)", function(): ()
            local a = buffer.create(8)
            fill(a, { 1, 2, 3, 4, 5, 6, 7, 8 })
            local b = buffer.create(8)
            fill(b, { 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22 })
            local once = Buf.xorApply(a, 8, b, 8)
            local twice = Buf.xorApply(once, 8, b, 8)
            expect(readBytes(twice, 8)):toEqual(readBytes(a, 8))
        end)
    end)

    describe("xorApply: differing lengths", function(): ()
        it("current longer than previous: XOR overlap, copy tail", function(): ()
            local cur = buffer.create(10)
            fill(cur, { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 })
            local prev = buffer.create(4)
            fill(prev, { 1, 2, 3, 4 })
            local out = Buf.xorApply(cur, 10, prev, 4)
            expect(readBytes(out, 10)):toEqual({ 0, 0, 0, 0, 5, 6, 7, 8, 9, 10 })
        end)
        it("current shorter than previous: XOR up to current length", function(): ()
            local cur = buffer.create(4)
            fill(cur, { 1, 2, 3, 4 })
            local prev = buffer.create(10)
            fill(prev, { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 })
            local out = Buf.xorApply(cur, 4, prev, 10)
            expect(buffer.len(out)):toBe(4)
            expect(readBytes(out, 4)):toEqual({ 0, 0, 0, 0 })
        end)
    end)

    describe("xorApply: alignment branches", function(): ()
        it("13-byte XOR exercises aligned8 + u32 + tail paths", function(): ()
            local cur = buffer.create(13)
            local prev = buffer.create(13)
            for i = 0, 12 do
                buffer.writeu8(cur, i, 0xFF)
                buffer.writeu8(prev, i, 0x0F)
            end
            local out = Buf.xorApply(cur, 13, prev, 13)
            for i = 0, 12 do
                expect(buffer.readu8(out, i)):toBe(0xF0)
            end
        end)
        it("3-byte XOR uses only the tail path", function(): ()
            local cur = buffer.create(3)
            fill(cur, { 0xAA, 0xBB, 0xCC })
            local prev = buffer.create(3)
            fill(prev, { 0x55, 0x44, 0x33 })
            local out = Buf.xorApply(cur, 3, prev, 3)
            expect(readBytes(out, 3)):toEqual({ 0xFF, 0xFF, 0xFF })
        end)
    end)

    describe("xorApply: result is a fresh buffer", function(): ()
        it("does not mutate current", function(): ()
            local cur = buffer.create(4)
            fill(cur, { 1, 2, 3, 4 })
            local prev = buffer.create(4)
            fill(prev, { 1, 2, 3, 4 })
            Buf.xorApply(cur, 4, prev, 4)
            expect(readBytes(cur, 4)):toEqual({ 1, 2, 3, 4 })
        end)
        it("does not mutate previous", function(): ()
            local cur = buffer.create(4)
            fill(cur, { 1, 2, 3, 4 })
            local prev = buffer.create(4)
            fill(prev, { 9, 9, 9, 9 })
            Buf.xorApply(cur, 4, prev, 4)
            expect(readBytes(prev, 4)):toEqual({ 9, 9, 9, 9 })
        end)
    end)
end)

return nil
