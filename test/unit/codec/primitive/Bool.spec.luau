--!strict
--!optimize 2
-- Behavior + metadata + bit-pack consequence for Lync.bool.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.primitive.Bool", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("metadata", function(): ()
        it("declares _size = 1", function(): ()
            expect((Lync.bool :: any)._size):toBe(1)
        end)
        it("flags _isBool", function(): ()
            expect((Lync.bool :: any)._isBool):toBe(true)
        end)
        it("declares _typeCheck = boolean", function(): ()
            expect((Lync.bool :: any)._typeCheck):toBe("boolean")
        end)
        it("exposes _directWrite and _directRead", function(): ()
            expect((Lync.bool :: any)._directWrite):toBeType("function")
            expect((Lync.bool :: any)._directRead):toBeType("function")
        end)
        it("is a frozen table", function(): ()
            expect(Lync.bool):toBeFrozen()
        end)
    end)

    describe("round-trip", function(): ()
        it("true encodes to 0x01 and decodes back", function(): ()
            local r = Channel.encode(Lync.bool, true)
            expect(r.length):toBe(1)
            expect(r.buffer):toMatchBuffer({ 0x01 })
            local v = Channel.decode(Lync.bool, r)
            expect(v):toBe(true)
        end)
        it("false encodes to 0x00 and decodes back", function(): ()
            local r = Channel.encode(Lync.bool, false)
            expect(r.length):toBe(1)
            expect(r.buffer):toMatchBuffer({ 0x00 })
            local v = Channel.decode(Lync.bool, r)
            expect(v):toBe(false)
        end)
        it("written byte count matches consumed byte count", function(): ()
            local _, written, consumed = Channel.roundTrip(Lync.bool, true)
            expect(written):toBe(consumed)
        end)
    end)

    describe("non-zero byte patterns decode as true", function(): ()
        --[[
            The decoder uses `readu8(b, off) ~= 0`. Any non-zero byte
            therefore decodes to true. Pin this since changing the rule
            would silently affect downstream readers.
        ]]
        it("byte 0x02 decodes as true", function(): ()
            local r = Channel.fromBytes({ 0x02 })
            local v = Channel.decode(Lync.bool, r)
            expect(v):toBe(true)
        end)
        it("byte 0xFF decodes as true", function(): ()
            local r = Channel.fromBytes({ 0xFF })
            local v = Channel.decode(Lync.bool, r)
            expect(v):toBe(true)
        end)
    end)

    describe("bit-pack consequence inside struct", function(): ()
        --[[
            _isBool drives the struct codec to pack consecutive bool
            fields into a shared byte. Eight bools must therefore fit in
            a single byte; nine require two.
        ]]
        it("eight bools in a struct fit in 1 byte", function(): ()
            local schema = {} :: any
            local data = {} :: any
            for i = 1, 8 do
                schema[`b{i}`] = Lync.bool
                data[`b{i}`] = i % 2 == 0
            end
            local r = Channel.encode(Lync.struct(schema), data)
            expect(r.length):toBe(1)
        end)
        it("nine bools spill to 2 bytes", function(): ()
            local schema = {} :: any
            local data = {} :: any
            for i = 1, 9 do
                schema[`b{i}`] = Lync.bool
                data[`b{i}`] = i % 3 == 0
            end
            local r = Channel.encode(Lync.struct(schema), data)
            expect(r.length):toBe(2)
        end)
        it("3 bools + 2 u8 = 3 bytes (u8s first, bool tail)", function(): ()
            local schema = {
                a = Lync.bool,
                b = Lync.bool,
                c = Lync.bool,
                x = Lync.int(0, 255),
                y = Lync.int(0, 255),
            }
            local r = Channel.encode(Lync.struct(schema), {
                a = true,
                b = false,
                c = true,
                x = 10,
                y = 20,
            })
            expect(r.length):toBe(3)
        end)
    end)
end)

return nil
