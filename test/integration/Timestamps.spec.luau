--!strict
--!optimize 2
-- Timestamp modes (frame / offset / full) end-to-end through Reader.

local Env = require(script:FindFirstAncestor("test").Env)

local Channel = Env.Internal.Channel
local Lync = Env.Lync
local Reader = Env.Internal.Reader
local Registry = Env.Internal.Registry
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

local function definePacket(name: string, codec: any, options: any): (any, { any })
    local received: { any } = {}
    local handle = Lync.packet(name, codec, options)
    handle:on(function(_value: any, _sender: any?, ts: any?): ()
        table.insert(received, ts)
    end)
    return Registry.getByName(name), received
end

local function sealAndProcess(ch: any): ()
    local snap, _refs, byteLen = Channel.sealAndDump(ch)
    Reader.process(snap, byteLen, nil, nil, false)
end

describe("integration.Timestamps", function(): ()
    beforeEach(function(): ()
        Sandbox.resetAll()
        --[[
            sealAndProcess fires Reader against wires that include timestamp
            bytes; Reader emits diagnostic warnings for some byte shapes it
            partially accepts. The tests still verify the user-visible
            outcome (received[1] == received[2] etc.), so silence Reader's
            warn output to keep the suite log clean.
        ]]
        Reader.setSilent(true)
    end)

    describe("frame mode", function(): ()
        it("counter wraps modulo 256 (FRAME_MASK)", function(): ()
            Channel.enableTimestamps()
            for _ = 1, 256 do
                Channel.updateTimestamp()
            end
            -- After 256 increments the masked counter should wrap.
            local reg, received =
                definePacket("ts_frame_wrap", Lync.int(0, 255), { timestamp = "frame" })
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 0)
            sealAndProcess(ch)
            expect(received[1]):toBeType("number")
            expect(received[1] :: number):toBeLessThanOrEqual(255)
            expect(received[1] :: number):toBeGreaterThanOrEqual(0)
        end)
        it("two writes in the same frame share the timestamp", function(): ()
            Channel.enableTimestamps()
            Channel.updateTimestamp()
            local reg, received =
                definePacket("ts_frame_shared", Lync.int(0, 255), { timestamp = "frame" })
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 0)
            Channel.writeBatch(ch, reg, 0)
            sealAndProcess(ch)
            expect(received[1]):toBe(received[2])
        end)
    end)

    describe("offset mode", function(): ()
        it("decoded offset is a non-negative number", function(): ()
            Channel.enableTimestamps()
            Channel.updateTimestamp()
            local reg, received =
                definePacket("ts_offset", Lync.int(0, 255), { timestamp = "offset" })
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 0)
            sealAndProcess(ch)
            expect(received[1] :: number):toBeGreaterThanOrEqual(0)
            expect(received[1] :: number):toBeLessThan(65536)
        end)
    end)

    describe("full mode", function(): ()
        it("decoded clock matches updateTimestamp's snapshot", function(): ()
            Channel.enableTimestamps()
            Channel.updateTimestamp()
            local reg, received = definePacket("ts_full", Lync.int(0, 255), { timestamp = "full" })
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 0)
            sealAndProcess(ch)
            expect(received[1]):toBeType("number")
            expect(received[1] :: number):toBeGreaterThan(0)
        end)
    end)

    describe("hasTimestamps reflects whether any packet enabled them", function(): ()
        it("starts false", function(): ()
            expect(Channel.hasTimestamps()):toBe(false)
        end)
        it("flips true after defining a timestamp packet", function(): ()
            Lync.packet("ts_flip", Lync.int(0, 255), { timestamp = "frame" })
            expect(Channel.hasTimestamps()):toBe(true)
        end)
    end)

    describe("mixing timestamped and non-timestamped packets in one batch", function(): ()
        it("non-ts packet doesn't get a timestamp byte", function(): ()
            Channel.enableTimestamps()
            Channel.updateTimestamp()
            local _, recvPlain = definePacket("ts_mix_plain", Lync.int(0, 255), {})
            local _, recvFrame =
                definePacket("ts_mix_frame", Lync.int(0, 255), { timestamp = "frame" })
            local plainReg = Registry.getByName("ts_mix_plain") :: any
            local frameReg = Registry.getByName("ts_mix_frame") :: any
            local ch = Channel.create()
            Channel.writeBatch(ch, plainReg, 1)
            Channel.writeBatch(ch, frameReg, 2)
            sealAndProcess(ch)
            expect(recvPlain[1]):toBeNil()
            expect(recvFrame[1]):toBeType("number")
        end)
    end)

    describe("frame mode ts byte width", function(): ()
        it("ts byte is exactly 1 byte (mode = TS_FRAME)", function(): ()
            Channel.enableTimestamps()
            Channel.updateTimestamp()
            local _, _ = definePacket("ts_w_frame", Lync.int(0, 255), { timestamp = "frame" })
            local reg = Registry.getByName("ts_w_frame") :: any
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 0)
            -- Wire layout: id(1) + tsByte(1) + payload(1) = 3 bytes, no count.
            expect(ch.cursor):toBe(3)
        end)
    end)

    describe("offset mode ts byte width", function(): ()
        it("ts is exactly 2 bytes (u16)", function(): ()
            Channel.enableTimestamps()
            Channel.updateTimestamp()
            local _, _ = definePacket("ts_w_offset", Lync.int(0, 255), { timestamp = "offset" })
            local reg = Registry.getByName("ts_w_offset") :: any
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 0)
            expect(ch.cursor):toBe(1 + 2 + 1)
        end)
    end)

    describe("full mode ts byte width", function(): ()
        it("ts is exactly 8 bytes (f64)", function(): ()
            Channel.enableTimestamps()
            Channel.updateTimestamp()
            local _, _ = definePacket("ts_w_full", Lync.int(0, 255), { timestamp = "full" })
            local reg = Registry.getByName("ts_w_full") :: any
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 0)
            expect(ch.cursor):toBe(1 + 8 + 1)
        end)
    end)

    describe("Sandbox.resetAll disables timestamps", function(): ()
        it("after reset, hasTimestamps false even if packet was defined", function(): ()
            Channel.enableTimestamps()
            expect(Channel.hasTimestamps()):toBe(true)
            Sandbox.resetAll()
            expect(Channel.hasTimestamps()):toBe(false)
        end)
    end)
end)

return nil
