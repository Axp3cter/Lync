--!strict
--!optimize 2
-- Signed two's complement helpers (writeI8/I16/I32 + readI8/I16/I32).

local Env = require(script:FindFirstAncestor("test").Env)

local Sandbox = Env.Sandbox
local Signed = Env.Internal.Signed

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.primitive.Signed", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("writeI8 produces correct two's complement", function(): ()
        it("0 -> 0x00", function(): ()
            local b = buffer.create(1)
            Signed.writeI8(b, 0, 0)
            expect(buffer.readu8(b, 0)):toBe(0)
        end)
        it("1 -> 0x01", function(): ()
            local b = buffer.create(1)
            Signed.writeI8(b, 0, 1)
            expect(buffer.readu8(b, 0)):toBe(1)
        end)
        it("-1 -> 0xFF", function(): ()
            local b = buffer.create(1)
            Signed.writeI8(b, 0, -1)
            expect(buffer.readu8(b, 0)):toBe(0xFF)
        end)
        it("-128 -> 0x80", function(): ()
            local b = buffer.create(1)
            Signed.writeI8(b, 0, -128)
            expect(buffer.readu8(b, 0)):toBe(0x80)
        end)
        it("127 -> 0x7F", function(): ()
            local b = buffer.create(1)
            Signed.writeI8(b, 0, 127)
            expect(buffer.readu8(b, 0)):toBe(0x7F)
        end)
    end)

    describe("writeI16 produces correct two's complement", function(): ()
        it("-1 -> 0xFFFF (little-endian)", function(): ()
            local b = buffer.create(2)
            Signed.writeI16(b, 0, -1)
            expect(buffer.readu16(b, 0)):toBe(0xFFFF)
        end)
        it("-32768 -> 0x8000", function(): ()
            local b = buffer.create(2)
            Signed.writeI16(b, 0, -32768)
            expect(buffer.readu16(b, 0)):toBe(0x8000)
        end)
        it("32767 -> 0x7FFF", function(): ()
            local b = buffer.create(2)
            Signed.writeI16(b, 0, 32767)
            expect(buffer.readu16(b, 0)):toBe(0x7FFF)
        end)
    end)

    describe("writeI32 produces correct two's complement", function(): ()
        it("-1 -> 0xFFFFFFFF", function(): ()
            local b = buffer.create(4)
            Signed.writeI32(b, 0, -1)
            expect(buffer.readu32(b, 0)):toBe(0xFFFFFFFF)
        end)
        it("-2147483648 -> 0x80000000", function(): ()
            local b = buffer.create(4)
            Signed.writeI32(b, 0, -2147483648)
            expect(buffer.readu32(b, 0)):toBe(0x80000000)
        end)
        it("2147483647 -> 0x7FFFFFFF", function(): ()
            local b = buffer.create(4)
            Signed.writeI32(b, 0, 2147483647)
            expect(buffer.readu32(b, 0)):toBe(0x7FFFFFFF)
        end)
    end)

    describe("write then read inverse", function(): ()
        local i8Cases = { -128, -64, -1, 0, 1, 64, 127 }
        for _, v in i8Cases do
            it(`i8 round-trip {v}`, function(): ()
                local b = buffer.create(1)
                Signed.writeI8(b, 0, v)
                expect(Signed.readI8(b, 0)):toBe(v)
            end)
        end

        local i16Cases = { -32768, -1000, -1, 0, 1, 1000, 32767 }
        for _, v in i16Cases do
            it(`i16 round-trip {v}`, function(): ()
                local b = buffer.create(2)
                Signed.writeI16(b, 0, v)
                expect(Signed.readI16(b, 0)):toBe(v)
            end)
        end

        local i32Cases = { -2147483648, -1000000, -1, 0, 1, 1000000, 2147483647 }
        for _, v in i32Cases do
            it(`i32 round-trip {v}`, function(): ()
                local b = buffer.create(4)
                Signed.writeI32(b, 0, v)
                expect(Signed.readI32(b, 0)):toBe(v)
            end)
        end
    end)
end)

return nil
