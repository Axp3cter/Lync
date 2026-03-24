--!strict
--!optimize 2
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

local function makeReg(id: number, name: string): any
    local codec = Lync.int(0, 255)
    return {
        id = id, name = name, kind = 0, codec = codec, isUnreliable = false,
        headerSize = 1, timestampMode = Channel.TS_NONE,
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

return nil
