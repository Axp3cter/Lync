--!strict
--!optimize 2
-- transport.Reader: MSB dispatch, multi-frame batching, timestamps, queries.

local Env = require(script:FindFirstAncestor("test").Env)

local Channel = Env.Internal.Channel
local Lync = Env.Lync
local Reader = Env.Internal.Reader
local Registry = Env.Internal.Registry
local Sandbox = Env.Sandbox
local Wire = Env.Wire

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

local function definePacket(name: string, codec: any, options: any?): (any, { any })
    local opts = options or {}
    local received: { any } = {}
    local handle = Lync.packet(name, codec, opts)
    handle:on(function(value: any, sender: any?, ts: any?): ()
        table.insert(received, { value = value, sender = sender, timestamp = ts })
    end)
    return Registry.getByName(name), received
end

local function sealAndProcess(ch: any, isServer: boolean?, player: any?): ()
    local snap, refs, byteLen = Channel.sealAndDump(ch)
    Reader.process(snap, byteLen, refs, player, isServer or false)
end

describe("transport.Reader", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("decodeIncoming", function(): ()
        it("returns nil for non-buffer types", function(): ()
            expect(Reader.decodeIncoming("not a buffer")):toBeNil()
            expect(Reader.decodeIncoming(123)):toBeNil()
            expect(Reader.decodeIncoming({})):toBeNil()
            expect(Reader.decodeIncoming(nil)):toBeNil()
        end)
        it("returns nil for empty buffer", function(): ()
            expect(Reader.decodeIncoming(buffer.create(0))):toBeNil()
        end)
        it("accepts non-empty buffer", function(): ()
            local b = buffer.create(8)
            expect(Reader.decodeIncoming(b)):toBe(b)
        end)
        it("accepts large buffers (> default channelMaxSize)", function(): ()
            local big = buffer.create(600 * 1024)
            expect(Reader.decodeIncoming(big)):toBe(big)
        end)
    end)

    describe("MSB single-mode dispatch", function(): ()
        it("decodes a single u8 packet", function(): ()
            local reg, received = definePacket("r_single_u8", Lync.int(0, 255))
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 42)
            sealAndProcess(ch)
            expect(#received):toBe(1)
            expect(received[1].value):toBe(42)
        end)
        it("decodes a variable-size payload (string)", function(): ()
            local reg, received = definePacket("r_single_var", Lync.string)
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, "hello")
            sealAndProcess(ch)
            expect(received[1].value):toBe("hello")
        end)
    end)

    describe("multi-mode batching", function(): ()
        it("2 fires of u8 decode in order", function(): ()
            local reg, received = definePacket("r_multi_2", Lync.int(0, 255))
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 7)
            Channel.writeBatch(ch, reg, 11)
            sealAndProcess(ch)
            expect(#received):toBe(2)
            expect(received[1].value):toBe(7)
            expect(received[2].value):toBe(11)
        end)
        it("100 fires decode in order", function(): ()
            local reg, received = definePacket("r_multi_100", Lync.int(0, 255))
            local ch = Channel.create()
            for i = 1, 100 do
                Channel.writeBatch(ch, reg, i % 256)
            end
            sealAndProcess(ch)
            expect(#received):toBe(100)
            for i = 1, 100 do
                if received[i].value ~= i % 256 then
                    error(`mismatch at index {i}: expected {i % 256}, got {received[i].value}`)
                end
            end
        end)
    end)

    describe("interleaved packet IDs", function(): ()
        it("A A B A pattern produces correct counts and order", function(): ()
            local regA, recvA = definePacket("r_mix_a", Lync.int(0, 255))
            local regB, recvB = definePacket("r_mix_b", Lync.int(0, 255))
            local ch = Channel.create()
            Channel.writeBatch(ch, regA, 10)
            Channel.writeBatch(ch, regA, 20)
            Channel.writeBatch(ch, regB, 99)
            Channel.writeBatch(ch, regA, 30)
            sealAndProcess(ch)
            expect(#recvA):toBe(3)
            expect(recvA[1].value):toBe(10)
            expect(recvA[2].value):toBe(20)
            expect(recvA[3].value):toBe(30)
            expect(#recvB):toBe(1)
            expect(recvB[1].value):toBe(99)
        end)
    end)

    describe("timestamp parsing", function(): ()
        it("frame timestamp surfaces in handler", function(): ()
            Channel.enableTimestamps()
            Channel.updateTimestamp()
            local reg, received = definePacket(
                "r_ts_frame",
                Lync.int(0, 255),
                { timestamp = "frame" }
            )
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 1)
            sealAndProcess(ch)
            expect(received[1].timestamp):toBeType("number")
        end)
        it("offset timestamp surfaces in handler", function(): ()
            Channel.enableTimestamps()
            Channel.updateTimestamp()
            local reg, received = definePacket(
                "r_ts_offset",
                Lync.int(0, 255),
                { timestamp = "offset" }
            )
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 1)
            sealAndProcess(ch)
            expect(received[1].timestamp):toBeType("number")
        end)
        it("full timestamp surfaces in handler", function(): ()
            Channel.enableTimestamps()
            Channel.updateTimestamp()
            local reg, received = definePacket(
                "r_ts_full",
                Lync.int(0, 255),
                { timestamp = "full" }
            )
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 1)
            sealAndProcess(ch)
            expect(received[1].timestamp):toBeType("number")
        end)
    end)

    describe("error handling", function(): ()
        it("unknown packet ID aborts current frame", function(): ()
            -- ID 0 is never assigned (Registry starts at 1).
            Reader.setSilent(true)
            local reg, received = definePacket("r_unknown", Lync.int(0, 255))
            local raw = buffer.create(3)
            buffer.writeu8(raw, 0, 0x80) -- single-mode, id 0 (unregistered)
            buffer.writeu8(raw, 1, bit32.bor(0x80, reg.id))
            buffer.writeu8(raw, 2, 7)
            Reader.process(raw, 3, nil, nil, false)
            expect(#received):toBe(0)
        end)
    end)

    describe("server-side gate path: maxPayloadBytes", function(): ()
        it("packet exceeding payload cap is dropped", function(): ()
            local reg, received = definePacket(
                "r_max_payload",
                Lync.string,
                { maxPayloadBytes = 5 }
            )
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, "way too long for the cap")
            sealAndProcess(ch, true, Instance.new("Folder"))
            expect(#received):toBe(0)
        end)
    end)

    describe("server-side validate callback", function(): ()
        it("rejects when validate returns false", function(): ()
            local reg, received = definePacket(
                "r_validate",
                Lync.int(0, 100),
                {
                    validate = function(_d: any, _p: any): (boolean, string?)
                        return false, "nope"
                    end,
                }
            )
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 5)
            sealAndProcess(ch, true, Instance.new("Folder"))
            expect(#received):toBe(0)
        end)
        it("accepts when validate returns true", function(): ()
            local reg, received = definePacket(
                "r_validate_pass",
                Lync.int(0, 100),
                {
                    validate = function(_d: any, _p: any): (boolean, string?)
                        return true, nil
                    end,
                }
            )
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 5)
            sealAndProcess(ch, true, Instance.new("Folder"))
            expect(#received):toBe(1)
        end)
    end)
end)

return nil
