--!strict
--!optimize 2
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Lync = require(script.Parent.Parent.Parent)
local Reader = require(script.Parent.Parent.Parent.transport.Reader)
local Registry = require(script.Parent.Parent.Parent.internal.Registry)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

-- Helpers ----------------------------------------------------------------

--[[
    Define a packet, capture every value its signal fires, and return:
      reg          — the Registry entry, ready for Channel.writeBatch
      received     — a list that gets appended to on each fire
    Reader.process uses :fire (async via task.spawn). spawnCallback hands
    the value to a non-yielding closure, which runs to completion before
    task.spawn returns, so by the time process returns the table is filled.
]]
local function definePacket(name: string, codec: any): (any, { any })
    local received: { any } = {}
    local handle = Lync.packet(name, codec)
    handle:on(function(value: any): ()
        table.insert(received, value)
    end)
    return Registry.getByName(name), received
end

local function sealAndProcess(ch: any, refs: { Instance }?, isServer: boolean?): ()
    local snap, sealedRefs, byteLen = Channel.sealAndDump(ch)
    Reader.process(snap, byteLen, refs or sealedRefs, nil, isServer or false)
end

-- Tests ------------------------------------------------------------------

describe("Reader.process: single-mode (MSB) packets", function(): ()
    it("decodes a single u8", function(): ()
        local reg, received = definePacket("__r_single_u8", Lync.int(0, 255))
        local ch = Channel.create()
        Channel.writeBatch(ch, reg, 42)
        sealAndProcess(ch)
        expect(#received):toBe(1)
        expect(received[1]):toBe(42)
    end)

    it("decodes a single variable-size payload (string)", function(): ()
        local reg, received = definePacket("__r_single_var", Lync.string)
        local ch = Channel.create()
        Channel.writeBatch(ch, reg, "hello world")
        sealAndProcess(ch)
        expect(#received):toBe(1)
        expect(received[1]):toBe("hello world")
    end)
end)

describe("Reader.process: multi-mode batching at scale", function(): ()
    it("2 fires of u8 decode in order", function(): ()
        local reg, received = definePacket("__r_multi_2", Lync.int(0, 255))
        local ch = Channel.create()
        Channel.writeBatch(ch, reg, 7)
        Channel.writeBatch(ch, reg, 11)
        sealAndProcess(ch)
        expect(#received):toBe(2)
        expect(received[1]):toBe(7)
        expect(received[2]):toBe(11)
    end)

    it("1000 fires of u8 decode in order", function(): ()
        local reg, received = definePacket("__r_multi_1000", Lync.int(0, 255))
        local ch = Channel.create()
        for i = 1, 1000 do
            Channel.writeBatch(ch, reg, i % 256)
        end
        sealAndProcess(ch)
        expect(#received):toBe(1000)
        for i = 1, 1000 do
            if received[i] ~= i % 256 then
                error(`mismatch at index {i}: expected {i % 256}, got {received[i]}`)
            end
        end
    end)

    it("65536 fires splits into two batches", function(): ()
        --[[
            writeBatch opens a new batch when itemCount reaches 0xFFFF, so
            65536 fires must produce two batches. The second batch should
            still decode cleanly in the outer Reader loop.
        ]]
        local reg, received = definePacket("__r_multi_65536", Lync.int(0, 255))
        local ch = Channel.create()
        for i = 1, 65536 do
            Channel.writeBatch(ch, reg, i % 256)
        end
        sealAndProcess(ch)
        expect(#received):toBe(65536)
    end)
end)

describe("Reader.process: large variable-size payloads (bench scenario)", function(): ()
    it("1000 fires of array(bool, 1000) decode all 1000 with 1000 elements each", function(): ()
        --[[
            This is the exact shape the bench fires under "1000x bools"
            comparison: Lync.array(Lync.bool) with a 1000-element array,
            fired 1000 times in a single batch. Each fire serializes to
            127 bytes (varint(1000)=2 + ceil(1000/8)=125), so the resulting
            buffer is 1 (header) + 2 (count) + 1000*127 = 127003 bytes.
            If multi-mode framing is wrong, decode goes off the rails
            mid-buffer and Reader emits "unknown packet ID at byte ...".
        ]]
        local reg, received = definePacket("__r_bench_bools", Lync.array(Lync.bool))
        local data = table.create(1000, true)
        local ch = Channel.create()
        for _ = 1, 1000 do
            Channel.writeBatch(ch, reg, data)
        end

        local _snap, _refs, byteLen = Channel.sealAndDump(ch)
        expect(byteLen):toBe(1 + 2 + 1000 * 127)

        sealAndProcess(ch)
        expect(#received):toBe(1000)
        expect(#received[1]):toBe(1000)
        expect(#received[500]):toBe(1000)
        expect(#received[1000]):toBe(1000)
        expect(received[1][1]):toBe(true)
        expect(received[500][500]):toBe(true)
        expect(received[1000][1000]):toBe(true)
    end)

    it("400 fires of array(struct(6×u8), 100) — bench 'entities' shape", function(): ()
        --[[
            Bench's "100x entities" comp test. blinkEntityCodec is a
            struct of six u8s (allDirect → _size=6, _directWrite). The
            outer Lync.array(blinkEntityCodec) uses makeDirectArray.
            Wire size per fire: 1 (varint(100)) + 100*6 = 601 bytes.
            Total: 1 + 2 + 400*601 = 240403 bytes (under default 256KB
            channelMaxSize). Bench uses 1000 fires with channelMaxSize
            configured to 1MB — same exercise, smaller scale.
        ]]
        local entityCodec = Lync.struct({
            id = Lync.int(0, 255),
            x = Lync.int(0, 255),
            y = Lync.int(0, 255),
            z = Lync.int(0, 255),
            orientation = Lync.int(0, 255),
            animation = Lync.int(0, 255),
        })
        local reg, received = definePacket("__r_bench_entities", Lync.array(entityCodec))

        local entity = { id = 7, x = 10, y = 20, z = 30, orientation = 40, animation = 50 }
        local data = table.create(100, entity)

        local ch = Channel.create()
        for _ = 1, 400 do
            Channel.writeBatch(ch, reg, data)
        end

        local _snap, _refs, byteLen = Channel.sealAndDump(ch)
        expect(byteLen):toBe(1 + 2 + 400 * 601)

        sealAndProcess(ch)
        expect(#received):toBe(400)
        expect(#received[1]):toBe(100)
        expect(received[200][50].id):toBe(7)
        expect(received[400][100].animation):toBe(50)
    end)
end)

describe("Reader.process: mixed batches in one buffer", function(): ()
    it("batch A then batch B back-to-back", function(): ()
        local regA, recvA = definePacket("__r_mix_a", Lync.int(0, 255))
        local regB, recvB = definePacket("__r_mix_b", Lync.int(0, 255))
        local ch = Channel.create()
        Channel.writeBatch(ch, regA, 1)
        Channel.writeBatch(ch, regA, 2)
        Channel.writeBatch(ch, regB, 99)
        sealAndProcess(ch)
        expect(recvA):toEqual({ 1, 2 })
        expect(recvB):toEqual({ 99 })
    end)

    it("A A B A pattern produces correct counts and order", function(): ()
        local regA, recvA = definePacket("__r_mix_aaba_a", Lync.int(0, 255))
        local regB, recvB = definePacket("__r_mix_aaba_b", Lync.int(0, 255))
        local ch = Channel.create()
        Channel.writeBatch(ch, regA, 10)
        Channel.writeBatch(ch, regA, 20)
        Channel.writeBatch(ch, regB, 99)
        Channel.writeBatch(ch, regA, 30)
        sealAndProcess(ch)
        expect(recvA):toEqual({ 10, 20, 30 })
        expect(recvB):toEqual({ 99 })
    end)

    it("20 different packet types each fired once", function(): ()
        --[[
            Registry caps at MAX_ID=127 so test packet count stays low.
            20 types verifies the outer while-loop in Reader walks
            independent batches correctly.
        ]]
        local regs: { any } = {}
        local recvs: { { any } } = {}
        for i = 1, 20 do
            local r, rec = definePacket(`__r_mix_20_{i}`, Lync.int(0, 255))
            regs[i] = r
            recvs[i] = rec
        end
        local ch = Channel.create()
        for i = 1, 20 do
            Channel.writeBatch(ch, regs[i], i)
        end
        sealAndProcess(ch)
        for i = 1, 20 do
            expect(#recvs[i]):toBe(1)
            expect(recvs[i][1]):toBe(i)
        end
    end)
end)

describe("Reader.process: error handling", function(): ()
    it("unknown packet ID aborts current frame", function(): ()
        local reg, received = definePacket("__r_err_id_zero", Lync.int(0, 255))
        --[[
            Registry assigns IDs starting at 1, so id 0 is permanently
            unregistered. Build [0x80 (id=0, MSB set)][trailing valid
            packet]. Reader must log "unknown packet ID" and return
            without dispatching the trailing valid frame.
        ]]
        local buf = buffer.create(3)
        buffer.writeu8(buf, 0, 0x80)
        buffer.writeu8(buf, 1, bit32.bor(0x80, reg.id))
        buffer.writeu8(buf, 2, 7)
        Reader.process(buf, 3, nil, nil, false)
        expect(#received):toBe(0)
    end)
end)

describe("Reader.decodeIncoming: receiver must not reject by local channelMaxSize", function(): ()
    --[[
        Regression: server and client run as independent Lua VMs with
        their own Channel module state. If the sender calls
        Lync.configure with a larger channelMaxSize than the receiver's
        default, frames that fit on the wire (Roblox's per-RemoteEvent
        cap is ~1MB) but exceed the *receiver's* local config were being
        silently dropped — and a dropped reliable frame permanently
        desyncs XOR delta. decodeIncoming must accept anything non-empty.
    ]]
    it("accepts a buffer larger than default 256KB local config", function(): ()
        local big = buffer.create(600 * 1024)
        expect(Reader.decodeIncoming(big)):toBe(big)
    end)
    it("accepts buffers up to the Roblox per-RemoteEvent ceiling (~1MB)", function(): ()
        local big = buffer.create(1024 * 1024)
        expect(Reader.decodeIncoming(big)):toBe(big)
    end)
    it("still rejects non-buffer arguments", function(): ()
        expect(Reader.decodeIncoming("not a buffer")):toBeNil()
        expect(Reader.decodeIncoming(nil)):toBeNil()
        expect(Reader.decodeIncoming(123)):toBeNil()
        expect(Reader.decodeIncoming({})):toBeNil()
    end)
    it("rejects empty buffer", function(): ()
        expect(Reader.decodeIncoming(buffer.create(0))):toBeNil()
    end)
end)

return nil
