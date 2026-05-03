--!strict
--!optimize 2
-- Single -> multi upgrade for fixed and variable-size codec families.

local Env = require(script:FindFirstAncestor("test").Env)

local Channel = Env.Internal.Channel
local Lync = Env.Lync
local Registry = Env.Internal.Registry
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

local function reg(name: string, codec: any?): any
    return Registry.register({
        name = name,
        kind = Registry.KIND_PACKET,
        codec = codec or Lync.int(0, 255),
        isUnreliable = false,
        partner = nil,
        needsGate = false,
        headerSize = 1,
        timestampMode = Channel.TS_NONE,
        openFn = Channel.resolveOpenFn(Channel.TS_NONE, name),
        rateLimit = nil,
        validate = nil,
        maxPayloadBytes = nil,
    })
end

describe("integration.BatchFraming", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("single-mode header", function(): ()
        it("first byte has MSB set", function(): ()
            local r = reg("a")
            local ch = Channel.create()
            Channel.writeBatch(ch, r, 42)
            expect(bit32.band(buffer.readu8(ch.buff, 0), 0x80)):toBe(0x80)
        end)
        it("ID readable by clearing MSB", function(): ()
            local r = reg("b")
            local ch = Channel.create()
            Channel.writeBatch(ch, r, 0)
            expect(bit32.band(buffer.readu8(ch.buff, 0), 0x7F)):toBe(r.id)
        end)
        it("single u8 packet = 2 bytes total (id + payload)", function(): ()
            local r = reg("c")
            local ch = Channel.create()
            Channel.writeBatch(ch, r, 5)
            expect(ch.cursor):toBe(2)
        end)
    end)

    describe("multi-mode upgrade for fixed-size codecs", function(): ()
        it("100 fires of u8: cursor = 1 + 2 + 100", function(): ()
            local r = reg("u8_100")
            local ch = Channel.create()
            for i = 1, 100 do
                Channel.writeBatch(ch, r, i % 256)
            end
            expect(ch.cursor):toBe(1 + 2 + 100)
        end)
        it("1000 fires of u8: cursor = 1 + 2 + 1000", function(): ()
            local r = reg("u8_1000")
            local ch = Channel.create()
            for i = 1, 1000 do
                Channel.writeBatch(ch, r, i % 256)
            end
            expect(ch.cursor):toBe(1 + 2 + 1000)
        end)
        it("65535 fires (max u16 count): 1 + 2 + 65535", function(): ()
            local r = reg("u8_max")
            local ch = Channel.create()
            for i = 1, 65535 do
                Channel.writeBatch(ch, r, i % 256)
                if i % 4096 == 0 then
                    task.wait()
                end
            end
            expect(ch.cursor):toBe(1 + 2 + 65535)
        end)
        it("65536 fires opens a fresh batch (1+2+65535 + 1+1)", function(): ()
            local r = reg("u8_overflow")
            local ch = Channel.create()
            for i = 1, 65536 do
                Channel.writeBatch(ch, r, i % 256)
                if i % 4096 == 0 then
                    task.wait()
                end
            end
            expect(ch.cursor):toBe(1 + 2 + 65535 + 1 + 1)
        end)
        it("count u16 at byte 1 finalizes to N after seal", function(): ()
            local r = reg("count_finalize")
            local ch = Channel.create()
            for i = 1, 1000 do
                Channel.writeBatch(ch, r, i % 256)
            end
            local snap = Channel.sealAndDump(ch)
            expect(buffer.readu16(snap, 1)):toBe(1000)
        end)
    end)

    describe("multi-mode upgrade for variable-size codecs", function(): ()
        it("1000 fires of array(bool, 1000): cursor = 1 + 2 + 1000*127", function(): ()
            local r = reg("bool_1k", Lync.array(Lync.bool))
            local data = table.create(1000, true)
            local ch = Channel.create()
            for _ = 1, 1000 do
                Channel.writeBatch(ch, r, data)
            end
            expect(ch.cursor):toBe(1 + 2 + 1000 * 127)
        end)
        it("each fire's first byte is the varint(1000) prefix 0xC3", function(): ()
            local r = reg("bool_drift", Lync.array(Lync.bool))
            local data = table.create(1000, true)
            local ch = Channel.create()
            for _ = 1, 300 do
                Channel.writeBatch(ch, r, data)
            end
            local snap = Channel.sealAndDump(ch)
            local mismatches = 0
            for fire = 1, 300 do
                local off = 3 + (fire - 1) * 127
                if buffer.readu8(snap, off) ~= 0xC3 then
                    mismatches += 1
                end
            end
            expect(mismatches):toBe(0)
        end)
    end)

    describe("interleaved IDs preserve framing", function(): ()
        it("A A B A pattern produces 5 + 2 + 2 = 9 bytes", function(): ()
            local a = reg("interleaved_a")
            local b = reg("interleaved_b")
            local ch = Channel.create()
            Channel.writeBatch(ch, a, 1)
            Channel.writeBatch(ch, a, 2)
            Channel.writeBatch(ch, b, 3)
            Channel.writeBatch(ch, a, 4)
            -- A multi: 1 (id) + 2 (count) + 2 (payload) = 5
            -- B single: 1 + 1 = 2
            -- A single: 1 + 1 = 2
            expect(ch.cursor):toBe(9)
        end)
    end)
end)

return nil
