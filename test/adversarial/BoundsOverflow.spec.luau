--!strict
--!optimize 2
-- Bounded codec enforcement: int range, string maxLength, array/map maxCount, sequence keypoint cap.

local Env = require(script:FindFirstAncestor("test").Env)

local Base = Env.Internal.Base
local Channel = Env.Channel
local InternalChannel = Env.Internal.Channel
local Lync = Env.Lync
local Sandbox = Env.Sandbox
local Wire = Env.Wire

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("adversarial.BoundsOverflow", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("string maxLength", function(): ()
        it("read of 20-char encoded string with maxLength 10 throws", function(): ()
            local r = Channel.encode(Lync.string, string.rep("x", 20))
            expect(function(): ()
                Lync.string(10).read(r.buffer, 0, nil)
            end):toThrow("exceeds max")
        end)
    end)

    describe("array maxCount", function(): ()
        it("read of 5-element encoded array with maxCount 3 throws", function(): ()
            local r = Channel.encode(Lync.array(Lync.int(0, 255)), { 1, 2, 3, 4, 5 })
            expect(function(): ()
                Lync.array(Lync.int(0, 255), 3).read(r.buffer, 0, nil)
            end):toThrow("exceeds max")
        end)
    end)

    describe("map maxCount", function(): ()
        it("read of 3-entry encoded map with maxCount 2 throws", function(): ()
            local r = Channel.encode(
                Lync.map(Lync.int(0, 255), Lync.int(0, 255)),
                { [1] = 10, [2] = 20, [3] = 30 }
            )
            expect(function(): ()
                Lync.map(Lync.int(0, 255), Lync.int(0, 255), 2).read(r.buffer, 0, nil)
            end):toThrow("exceeds max")
        end)
    end)

    describe("Channel buffer max size", function(): ()
        it("alloc beyond configured max throws", function(): ()
            Base.setMaxSize(2048)
            local ch = InternalChannel.create()
            ch.cursor = 2000
            expect(function(): ()
                Base.alloc(ch, 1000)
            end):toThrow("overflow")
        end)
    end)

    describe("pushRef overflow guard", function(): ()
        it("> 65535 refs throws", function(): ()
            local ch = InternalChannel.create()
            ch.refCount = 0xFFFF
            ch.refs[0xFFFF] = {} :: any
            expect(function(): ()
                InternalChannel.pushRef(ch, {})
            end):toThrow("ref overflow")
        end)
    end)

    describe("Sequence keypoint cap", function(): ()
        it("NumberSequence count > 20 rejected on read", function(): ()
            local b = Wire.bufferFromBytes({ 21 })
            local padded = buffer.create(1 + 21 * 12)
            buffer.copy(padded, 0, b, 0, 1)
            expect(function(): ()
                Lync.numberSequence.read(padded, 0, nil)
            end):toThrow("Roblox limit")
        end)
        it("ColorSequence count > 20 rejected on read", function(): ()
            local b = buffer.create(1 + 21 * 7)
            buffer.writeu8(b, 0, 21)
            expect(function(): ()
                Lync.colorSequence.read(b, 0, nil)
            end):toThrow("Roblox limit")
        end)
    end)

    describe("int range bounds: write does NOT validate (Gate.validate's job)", function(): ()
        --[[
            Pin the actual contract: Lync.int picks the narrowest underlying
            wire type and writes through buffer.write* directly. The integer
            codec does NOT bounds-check at write time. Sender-side bounds
            enforcement is Gate.validate's responsibility, exercised by the
            outbound pipeline before reaching the codec write. Test the
            current behavior so any future "validate at write" change has
            to update this contract on purpose.
        ]]
        it("write of value below min wraps via underlying buffer.writeu*", function(): ()
            local c = Lync.int(10, 100)
            expect(function(): ()
                Channel.encode(c, 5)
            end).never:toThrow()
        end)
        it("Gate.validate catches below-min before write", function(): ()
            local Gate = Env.Internal.Gate
            local c = Lync.int(10, 100)
            local reason = Gate.validate(5, c)
            expect(reason).never:toBe(nil)
        end)
        it("Gate.validate catches above-max before write", function(): ()
            local Gate = Env.Internal.Gate
            local c = Lync.int(0, 100)
            local reason = Gate.validate(999, c)
            expect(reason).never:toBe(nil)
        end)
    end)

    describe("Varint upper bound", function(): ()
        it("Varint.write rejects value > U32_MAX", function(): ()
            local Varint = Env.Internal.Varint
            local InternalChannel = Env.Internal.Channel
            expect(function(): ()
                Varint.write(InternalChannel.create(), 0x100000001)
            end):toThrow()
        end)
        it("Varint.write rejects negative", function(): ()
            local Varint = Env.Internal.Varint
            local InternalChannel = Env.Internal.Channel
            expect(function(): ()
                Varint.write(InternalChannel.create(), -1)
            end):toThrow()
        end)
        it("Varint.write rejects fractional", function(): ()
            local Varint = Env.Internal.Varint
            local InternalChannel = Env.Internal.Channel
            expect(function(): ()
                Varint.write(InternalChannel.create(), 1.5)
            end):toThrow()
        end)
    end)

    describe("Bitfield total bit budget", function(): ()
        it("33 bits across uint fields throws at define", function(): ()
            expect(function(): ()
                Lync.bitfield({
                    a = { type = "uint", width = 32 },
                    b = { type = "uint", width = 1 },
                })
            end):toThrow("32 bits")
        end)
    end)

    describe("Tagged variant cap", function(): ()
        it("257 variants throws at define time", function(): ()
            local schema: { [string]: any } = {}
            for i = 1, 257 do
                schema[`v_{i}`] = Lync.struct({ x = Lync.int(0, 255) })
            end
            expect(function(): ()
                Lync.tagged("t", schema)
            end):toThrow()
        end)
    end)

    describe("Enum variant cap", function(): ()
        it("257 variants throws at define time", function(): ()
            local args = table.create(257)
            for i = 1, 257 do
                args[i] = `v_{i}`
            end
            expect(function(): ()
                Lync.enum(table.unpack(args))
            end):toThrow()
        end)
    end)

    describe("nested bounds: bounded array of bounded strings", function(): ()
        it("inner string cap fires before outer array cap", function(): ()
            local inner = Lync.string(3)
            local arr = Lync.array(inner, 10)
            -- Encode an unbounded array of long strings, then read with bounded.
            local r = Channel.encode(Lync.array(Lync.string), { "abcdef" })
            expect(function(): ()
                arr.read(r.buffer, 0, nil)
            end):toThrow()
        end)
    end)
end)

return nil
