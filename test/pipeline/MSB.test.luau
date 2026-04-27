--!strict
--!optimize 2
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

local function makeReg(id: number, name: string): any
    local codec = Lync.int(0, 255)
    return {
        id = id,
        name = name,
        kind = 0,
        codec = codec,
        isUnreliable = false,
        headerSize = 1,
        timestampMode = Channel.TS_NONE,
        _openFn = Channel.resolveOpenFn(Channel.TS_NONE, name),
    }
end

describe("MSB: single-item = 1 byte header", function(): ()
    it("first byte has MSB set", function(): ()
        local ch = Channel.create()
        Channel.writeBatch(ch, makeReg(1, "__msb1"), 42)
        expect(bit32.band(buffer.readu8(ch.buff, 0), 0x80)):toBe(0x80)
    end)
    it("ID recovered by clearing MSB", function(): ()
        local ch = Channel.create()
        Channel.writeBatch(ch, makeReg(5, "__msb_id"), 42)
        expect(bit32.band(buffer.readu8(ch.buff, 0), 0x7F)):toBe(5)
    end)
    it("total = 1 header + 1 payload = 2 bytes", function(): ()
        local ch = Channel.create()
        Channel.writeBatch(ch, makeReg(1, "__msb_size"), 42)
        expect(ch.cursor):toBe(2)
    end)
    it("saves 2 bytes vs old 3-byte header", function(): ()
        local ch = Channel.create()
        Channel.writeBatch(ch, makeReg(1, "__msb_save"), 0)
        -- Old format: id(1) + count(2) + payload(1) = 4; new: id(1) + payload(1) = 2
        expect(ch.cursor):toBe(2)
    end)
end)

describe("MSB: multi-item upgrades header", function(): ()
    it("two sends → MSB cleared", function(): ()
        local reg = makeReg(2, "__msb_multi")
        local ch = Channel.create()
        Channel.writeBatch(ch, reg, 10)
        Channel.writeBatch(ch, reg, 20)
        expect(bit32.band(buffer.readu8(ch.buff, 0), 0x80)):toBe(0)
    end)
    it("ID still correct after upgrade", function(): ()
        local reg = makeReg(3, "__msb_multi_id")
        local ch = Channel.create()
        Channel.writeBatch(ch, reg, 10)
        Channel.writeBatch(ch, reg, 20)
        expect(bit32.band(buffer.readu8(ch.buff, 0), 0x7F)):toBe(3)
    end)
end)

describe("MSB: interleaved packets", function(): ()
    it("two different IDs = two separate single-item batches", function(): ()
        local ch = Channel.create()
        Channel.writeBatch(ch, makeReg(3, "__msb_a"), 1)
        Channel.writeBatch(ch, makeReg(4, "__msb_b"), 2)
        expect(ch.cursor):toBe(4) -- 2 × (1 header + 1 payload)
    end)
    it("A A B A = multi(A:2) + single(B) + single(A)", function(): ()
        local regA = makeReg(5, "__msb_ia")
        local regB = makeReg(6, "__msb_ib")
        local ch = Channel.create()
        Channel.writeBatch(ch, regA, 1)
        Channel.writeBatch(ch, regA, 2)
        Channel.writeBatch(ch, regB, 3)
        Channel.writeBatch(ch, regA, 4)
        -- Multi A: id(1) + count(2) + 2×payload(2) = 5
        -- Single B: id(1) + payload(1) = 2
        -- Single A: id(1) + payload(1) = 2
        -- Total = 9
        expect(ch.cursor):toBe(9)
    end)
end)

describe("MSB: large multi-item batches (wire-size formula)", function(): ()
    --[[
        Wire-size invariant for N >= 2 fires of a fixed-size codec:
            cursor == 1 (id) + 2 (count) + N * payloadSize
        N == 1 stays in single-mode and is 1 + payloadSize. These tests
        verify the upgrade memmove and count finalization don't drop or
        duplicate bytes at scale — the bench fires 1000+ per frame.
    ]]
    it("100 fires of 1B payload: cursor = 3 + 100", function(): ()
        local reg = makeReg(7, "__msb_n100")
        local ch = Channel.create()
        for i = 1, 100 do
            Channel.writeBatch(ch, reg, i % 256)
        end
        expect(ch.cursor):toBe(1 + 2 + 100)
    end)
    it("1000 fires of 1B payload: cursor = 3 + 1000", function(): ()
        local reg = makeReg(8, "__msb_n1000")
        local ch = Channel.create()
        for i = 1, 1000 do
            Channel.writeBatch(ch, reg, i % 256)
        end
        expect(ch.cursor):toBe(1 + 2 + 1000)
    end)
    it("65535 fires (max u16 count): cursor = 3 + 65535", function(): ()
        local reg = makeReg(9, "__msb_max_count")
        local ch = Channel.create()
        for i = 1, 65535 do
            Channel.writeBatch(ch, reg, i % 256)
        end
        expect(ch.cursor):toBe(1 + 2 + 65535)
    end)
    it("65536 fires: opens a second batch (3 + 65535 + 2 + 1)", function(): ()
        --[[
            writeBatch's `itemCount >= 0xFFFF` guard opens a fresh batch
            once the previous one hits 65535 items. The 65536th fire
            therefore produces: 3 + 65535 (first batch) + 2 (single-mode
            header for second batch since itemCount=1) = 65541.
        ]]
        local reg = makeReg(10, "__msb_overflow")
        local ch = Channel.create()
        for i = 1, 65536 do
            Channel.writeBatch(ch, reg, i % 256)
        end
        expect(ch.cursor):toBe(1 + 2 + 65535 + 1 + 1)
    end)
    it("count u16 at byte 1 finalizes to N after seal", function(): ()
        local reg = makeReg(11, "__msb_count_finalized")
        local ch = Channel.create()
        for i = 1, 1000 do
            Channel.writeBatch(ch, reg, i % 256)
        end
        local snap, _, _ = Channel.sealAndDump(ch)
        expect(buffer.readu16(snap, 1)):toBe(1000)
    end)
end)

describe("MSB: variable-size payloads stay aligned at scale", function(): ()
    --[[
        Multi-fire of a variable-size codec (array(bool)) is the bench
        case that triggers the "unknown packet ID at byte 34003" warning.
        Each fire writes: varint(len)=2B + ceil(len/8) packed bytes.
        For len=1000 that's 127B per fire. Verify the cursor and the
        count placeholder stay correct.
    ]]
    it("1000 fires of array(bool, 1000) — cursor = 3 + 1000*127", function(): ()
        local Lync = require(script.Parent.Parent.Parent)
        local Registry = require(script.Parent.Parent.Parent.internal.Registry)

        Lync.packet("__msb_blink_bools", Lync.array(Lync.bool))
        local reg = Registry.getByName("__msb_blink_bools") :: any
        local data = table.create(1000, true)

        local ch = Channel.create()
        for _ = 1, 1000 do
            Channel.writeBatch(ch, reg, data)
        end
        expect(ch.cursor):toBe(1 + 2 + 1000 * 127)
    end)
    it("each fire offset = 3 + (i-1)*127 (no drift)", function(): ()
        local Lync = require(script.Parent.Parent.Parent)
        local Registry = require(script.Parent.Parent.Parent.internal.Registry)

        Lync.packet("__msb_drift", Lync.array(Lync.bool))
        local reg = Registry.getByName("__msb_drift") :: any
        local data = table.create(1000, true)

        local ch = Channel.create()
        for _ = 1, 300 do
            Channel.writeBatch(ch, reg, data)
        end

        local snap, _, _ = Channel.sealAndDump(ch)
        --[[
            Every fire's first byte is the varint for 1000 = 0xC3.
            If the upgrade memmove dropped or duplicated bytes, one of
            these checks would fail.
        ]]
        for fire = 1, 300 do
            local off = 3 + (fire - 1) * 127
            local b0 = buffer.readu8(snap, off)
            if b0 ~= 0xC3 then
                error(
                    `fire #{fire} at byte {off}: expected 0xC3, got 0x{string.format("%02X", b0)}`
                )
            end
        end
    end)
end)

return nil
