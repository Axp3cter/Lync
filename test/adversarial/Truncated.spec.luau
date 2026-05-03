--!strict
--!optimize 2
-- Truncated buffer rejection across every variable-size codec.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Sandbox = Env.Sandbox
local Wire = Env.Wire

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("adversarial.Truncated", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("string", function(): ()
        it("declared length exceeds buffer", function(): ()
            local buf = Wire.bufferFromBytes({ 100, 0x61, 0x62 })
            expect(function(): ()
                Lync.string.read(buf, 0, nil)
            end):toThrow("exceeds")
        end)
        it("varint length but no data", function(): ()
            local buf = Wire.bufferFromBytes({ 50 })
            expect(function(): ()
                Lync.string.read(buf, 0, nil)
            end):toThrow("exceeds")
        end)
    end)

    describe("buffer", function(): ()
        it("declared length exceeds buffer", function(): ()
            local buf = Wire.bufferFromBytes({ 50, 0x00, 0x00 })
            expect(function(): ()
                Lync.buff.read(buf, 0, nil)
            end):toThrow("exceeds")
        end)
    end)

    describe("varint", function(): ()
        --[[
            Varint.read is intentionally non-throwing on truncation: it
            returns (0, 0) so the transport can abort the frame on a
            zero-byte consume rather than crashing the buffer access.
        ]]
        it("2-byte tier truncated to 1 byte returns (0, 0)", function(): ()
            local Varint = Env.Internal.Varint
            local buf = Wire.bufferFromBytes({ 0xC0 })
            local v, consumed = Varint.read(buf, 0)
            expect(v):toBe(0)
            expect(consumed):toBe(0)
        end)
    end)

    describe("array (fixed-size element)", function(): ()
        --[[
            Direct-array read aborts when the declared count would walk past
            the buffer. The transport drops the baseline rather than yielding
            a partial decode that masks a desync.
        ]]
        it("count claims more elements than fit; throws", function(): ()
            local Varint = Env.Internal.Varint
            local InternalChannel = Env.Internal.Channel
            local ch = InternalChannel.create()
            Varint.write(ch, 100)
            -- Provide only 5 bytes of u8 payload after the count varint.
            for i = 1, 5 do
                buffer.writeu8(ch.buff, ch.cursor, i)
                ch.cursor += 1
            end
            local buf = buffer.create(ch.cursor)
            buffer.copy(buf, 0, ch.buff, 0, ch.cursor)
            local arr = Lync.array(Lync.int(0, 255))
            expect(function(): ()
                arr.read(buf, 0, nil)
            end):toThrow("exceeds remaining")
        end)
    end)

    describe("numberSequence", function(): ()
        it("count > 20 (Roblox limit) throws", function(): ()
            local b = buffer.create(1 + 21 * 12)
            buffer.writeu8(b, 0, 21)
            expect(function(): ()
                Lync.numberSequence.read(b, 0, nil)
            end):toThrow("Roblox limit")
        end)
        it("count fits but data missing throws", function(): ()
            local b = buffer.create(1)
            buffer.writeu8(b, 0, 5)
            expect(function(): ()
                Lync.numberSequence.read(b, 0, nil)
            end):toThrow("exceeds remaining")
        end)
    end)

    describe("colorSequence", function(): ()
        it("count > 20 throws", function(): ()
            local b = buffer.create(1 + 21 * 7)
            buffer.writeu8(b, 0, 21)
            expect(function(): ()
                Lync.colorSequence.read(b, 0, nil)
            end):toThrow("Roblox limit")
        end)
    end)

    describe("Instance / Unknown", function(): ()
        it("Instance.read with nil refs throws", function(): ()
            local buf = Wire.bufferFromBytes({ 0x01, 0x00 })
            expect(function(): ()
                Lync.inst.read(buf, 0, nil)
            end):toThrow("refs array is required")
        end)
        it("Instance.read out-of-bounds index", function(): ()
            local buf = Wire.bufferFromBytes({ 0x05, 0x00 })
            expect(function(): ()
                Lync.inst.read(buf, 0, {} :: any)
            end):toThrow("out of bounds")
        end)
        it("Unknown.read with nil refs throws", function(): ()
            local buf = Wire.bufferFromBytes({ 0x01, 0x00 })
            expect(function(): ()
                Lync.unknown.read(buf, 0, nil)
            end):toThrow("refs array is required")
        end)
    end)
end)

return nil
