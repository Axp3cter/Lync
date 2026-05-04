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

    describe("zero-size codec dispatch (Lync.nothing)", function(): ()
        --[[
            Lync.nothing has _size = 0 and reads 0 bytes. The per-iter checks
            `pos >= incomingLen` and `consumed == 0` would falsely abort here
            without the isZeroSize gate.
        ]]
        it("single Lync.nothing packet decodes without aborting", function(): ()
            local _, received = definePacket("r_nothing_single", Lync.nothing)
            local reg = Registry.getByName("r_nothing_single")
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, nil)
            sealAndProcess(ch)
            expect(#received):toBe(1)
            expect(received[1].value):toBeNil()
        end)
        it("multiple Lync.nothing packets in a batch all dispatch", function(): ()
            local _, received = definePacket("r_nothing_multi", Lync.nothing)
            local reg = Registry.getByName("r_nothing_multi")
            local ch = Channel.create()
            for _ = 1, 5 do
                Channel.writeBatch(ch, reg, nil)
            end
            sealAndProcess(ch)
            expect(#received):toBe(5)
        end)
        it("Lync.nothing followed by a u8 packet both decode", function(): ()
            local _, recvNothing = definePacket("r_nothing_then_u8_n", Lync.nothing)
            local _, recvInt = definePacket("r_nothing_then_u8_i", Lync.int(0, 255))
            local regN = Registry.getByName("r_nothing_then_u8_n")
            local regI = Registry.getByName("r_nothing_then_u8_i")
            local ch = Channel.create()
            Channel.writeBatch(ch, regN, nil)
            Channel.writeBatch(ch, regI, 42)
            sealAndProcess(ch)
            expect(#recvNothing):toBe(1)
            expect(#recvInt):toBe(1)
            expect(recvInt[1].value):toBe(42)
        end)
    end)

    describe("query response with Lync.nothing decodes (zero-size response codec)", function(): ()
        -- Mirror packet-side fix: 0-byte response codec must not trip the pos/consumed gates.
        it("MSB-clear response with Lync.nothing codec does not abort", function(): ()
            -- Register a KIND_RESPONSE directly so we can drive the response
            -- decode path with a known reg + Lync.nothing codec.
            local respReg = Registry.register({
                name = "r_q_resp_nothing",
                kind = Registry.KIND_RESPONSE,
                codec = Lync.nothing,
                isUnreliable = false,
                partner = nil,
                needsGate = false,
                headerSize = 1,
                timestampMode = Channel.TS_NONE,
                openFn = Channel.resolveOpenFn(Channel.TS_NONE, "r_q_resp_nothing"),
                rateLimit = nil,
                validate = nil,
                maxPayloadBytes = nil,
            })
            -- Hook the response signal so the test sees the dispatch fire.
            local fired = false
            respReg.signal:connect(function(): ()
                fired = true
            end)

            -- Write a payload-style response frame: MSB clear, corrId varint,
            -- then zero codec payload bytes from Lync.nothing.write.
            local ch = Channel.create()
            Channel.writeQuery(ch, respReg.id, 1, Lync.nothing :: any, true)
            local snap, refs, byteLen = Channel.sealAndDump(ch)
            -- Pre-fix: would warn "query body missing" or "reported 0 bytes" and abort.
            expect(Reader.process(snap, byteLen, refs, nil, false)):toBe(true)
            expect(fired):toBe(true)
        end)
    end)

    describe("fixed-size codec consumed-invariant", function(): ()
        it("a buggy codec returning consumed != _size aborts the frame", function(): ()
            -- Synthesize a codec that claims _size = 4 but reports consumed = 2.
            local lyingCodec: any = {
                _size = 4,
                write = function(ch: any, _v: any): ()
                    -- Write 4 bytes so the buffer matches the declared size.
                    if ch.cursor + 4 > ch.size then
                        Env.Internal.Base.alloc(ch, 4)
                    end
                    buffer.writeu32(ch.buff, ch.cursor, 0)
                    ch.cursor += 4
                end,
                read = function(_b: buffer, _pos: number, _refs: any): (number, number)
                    return 0, 2 -- contradicts _size = 4
                end,
            }
            local _, received = definePacket("r_lying_codec", lyingCodec)
            local reg = Registry.getByName("r_lying_codec")
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 0)
            sealAndProcess(ch)
            expect(#received):toBe(0)
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
            local reg, received =
                definePacket("r_ts_frame", Lync.int(0, 255), { timestamp = "frame" })
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 1)
            sealAndProcess(ch)
            expect(received[1].timestamp):toBeType("number")
        end)
        it("offset timestamp surfaces in handler", function(): ()
            Channel.enableTimestamps()
            Channel.updateTimestamp()
            local reg, received =
                definePacket("r_ts_offset", Lync.int(0, 255), { timestamp = "offset" })
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 1)
            sealAndProcess(ch)
            expect(received[1].timestamp):toBeType("number")
        end)
        it("full timestamp surfaces in handler", function(): ()
            Channel.enableTimestamps()
            Channel.updateTimestamp()
            local reg, received =
                definePacket("r_ts_full", Lync.int(0, 255), { timestamp = "full" })
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
            local reg, received =
                definePacket("r_max_payload", Lync.string, { maxPayloadBytes = 5 })
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, "way too long for the cap")
            sealAndProcess(ch, true, Instance.new("Folder"))
            expect(#received):toBe(0)
        end)
    end)

    describe("recvFires accounting (bulk-attributed at end of batch)", function(): ()
        it("recvFires sums to dispatched count after a batch", function(): ()
            Channel.enableStats()
            local reg, received = definePacket("r_recvfires_bulk", Lync.int(0, 255))
            local ch = Channel.create()
            for i = 1, 7 do
                Channel.writeBatch(ch, reg, i)
            end
            sealAndProcess(ch)
            expect(#received):toBe(7)
            expect(reg.recvFires):toBe(7)
        end)
        it("dropped (gated) items don't bump recvFires", function(): ()
            Channel.enableStats()
            local reg, received = definePacket("r_recvfires_dropped", Lync.int(0, 100), {
                validate = function(v: any, _p: any): (boolean, string?)
                    return v < 50, "too big"
                end,
            })
            local ch = Channel.create()
            -- 3 below threshold + 2 above threshold = 3 dispatched.
            for _, v in { 10, 20, 30, 75, 80 } do
                Channel.writeBatch(ch, reg, v)
            end
            sealAndProcess(ch, true, Instance.new("Folder"))
            expect(#received):toBe(3)
            expect(reg.recvFires):toBe(3)
        end)
    end)

    describe("server-side validate callback", function(): ()
        it("rejects when validate returns false", function(): ()
            local reg, received = definePacket("r_validate", Lync.int(0, 100), {
                validate = function(_d: any, _p: any): (boolean, string?)
                    return false, "nope"
                end,
            })
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 5)
            sealAndProcess(ch, true, Instance.new("Folder"))
            expect(#received):toBe(0)
        end)
        it("accepts when validate returns true", function(): ()
            local reg, received = definePacket("r_validate_pass", Lync.int(0, 100), {
                validate = function(_d: any, _p: any): (boolean, string?)
                    return true, nil
                end,
            })
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 5)
            sealAndProcess(ch, true, Instance.new("Folder"))
            expect(#received):toBe(1)
        end)
    end)
end)

return nil
