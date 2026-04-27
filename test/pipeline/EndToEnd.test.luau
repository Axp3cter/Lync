--!strict
--!optimize 2
-- End-to-end pipeline tests. These mimic the actual transport flow
-- without going through Roblox RemoteEvents:
--   write batch -> sealAndDump -> xorApply (encode) -> xorApply (decode)
--   -> Reader.process. If any link in the chain is wrong this catches it.

local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Lync = require(script.Parent.Parent.Parent)
local Reader = require(script.Parent.Parent.Parent.transport.Reader)
local Registry = require(script.Parent.Parent.Parent.internal.Registry)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

-- Helpers ----------------------------------------------------------------

local function definePacket(name: string, codec: any): (any, { any })
    local received: { any } = {}
    local handle = Lync.packet(name, codec)
    handle:on(function(value: any): ()
        table.insert(received, value)
    end)
    return Registry.getByName(name), received
end

--[[
    Simulate one server->client frame. Returns the new (prevSnap, prevLen)
    on the sender side and (prevDecoded, prevDecodedLen) on the receiver
    side. Both sides must end up with identical baselines or XOR delta
    diverges on the next frame.
]]
local function transmitOneFrame(
    senderCh: any,
    senderPrev: buffer?,
    senderPrevLen: number,
    receiverPrev: buffer?,
    receiverPrevLen: number
): (buffer, number, buffer, number)
    local snap, _refs, byteLen = Channel.sealAndDump(senderCh)
    local wire = Channel.xorApply(snap, byteLen, senderPrev, senderPrevLen)
    local decoded = Channel.xorApply(wire, byteLen, receiverPrev, receiverPrevLen)
    Reader.process(decoded, byteLen, nil, nil, false)
    Channel.reset(senderCh)
    return snap, byteLen, decoded, byteLen
end

-- Tests ------------------------------------------------------------------

describe("EndToEnd: identical-content frames stay decoded across XOR delta", function(): ()
    it("3 frames of same u8 packet decode all 3 times", function(): ()
        local reg, received = definePacket("__e2e_same_u8", Lync.int(0, 255))

        local senderPrev, senderPrevLen: buffer?, number = nil, 0
        local recvPrev, recvPrevLen: buffer?, number = nil, 0

        for _ = 1, 3 do
            local ch = Channel.create()
            Channel.writeBatch(ch, reg, 42)
            senderPrev, senderPrevLen, recvPrev, recvPrevLen =
                transmitOneFrame(ch, senderPrev, senderPrevLen, recvPrev, recvPrevLen)
        end

        expect(#received):toBe(3)
        expect(received[1]):toBe(42)
        expect(received[2]):toBe(42)
        expect(received[3]):toBe(42)
    end)

    it("5 frames of 1000 fires of array(bool, 1000) — bench bools shape", function(): ()
        local reg, received = definePacket("__e2e_bench_bools", Lync.array(Lync.bool))
        local data = table.create(1000, true)

        local senderPrev, senderPrevLen: buffer?, number = nil, 0
        local recvPrev, recvPrevLen: buffer?, number = nil, 0

        for _ = 1, 5 do
            local ch = Channel.create()
            for _ = 1, 1000 do
                Channel.writeBatch(ch, reg, data)
            end
            senderPrev, senderPrevLen, recvPrev, recvPrevLen =
                transmitOneFrame(ch, senderPrev, senderPrevLen, recvPrev, recvPrevLen)
        end

        --[[
            Each frame fires 1000 array values, 5 frames → 5000 total.
            If XOR delta drift OR multi-mode framing drifted at any
            point, one of the frames would emit "unknown packet ID" and
            received would be short.
        ]]
        expect(#received):toBe(5000)
        expect(#received[5000]):toBe(1000)
    end)

    it("5 frames of 400 fires of array(struct(6×u8), 100) — bench entities shape", function(): ()
        --[[
            400 fires of 601B payload = 240403B per frame, under the
            default 256KB channelMaxSize. Bench uses 1000 fires/frame
            with channelMaxSize bumped to 1MB; the multi-fire framing
            is the same exercise either way.
        ]]
        local entityCodec = Lync.struct({
            id = Lync.int(0, 255),
            x = Lync.int(0, 255),
            y = Lync.int(0, 255),
            z = Lync.int(0, 255),
            orientation = Lync.int(0, 255),
            animation = Lync.int(0, 255),
        })
        local reg, received = definePacket("__e2e_bench_entities", Lync.array(entityCodec))

        local entity = { id = 1, x = 2, y = 3, z = 4, orientation = 5, animation = 6 }
        local data = table.create(100, entity)

        local senderPrev, senderPrevLen: buffer?, number = nil, 0
        local recvPrev, recvPrevLen: buffer?, number = nil, 0

        for _ = 1, 5 do
            local ch = Channel.create()
            for _ = 1, 400 do
                Channel.writeBatch(ch, reg, data)
            end
            senderPrev, senderPrevLen, recvPrev, recvPrevLen =
                transmitOneFrame(ch, senderPrev, senderPrevLen, recvPrev, recvPrevLen)
        end

        expect(#received):toBe(2000)
        expect(received[2000][100].animation):toBe(6)
    end)
end)

describe("EndToEnd: frame-size transitions across XOR delta", function(): ()
    --[[
        Bench transitions between tests of different shapes. The XOR delta
        must stay correct when prev is longer than current and vice versa.
        These shrink/grow scenarios are what the comp test does going from
        100x entities (601000B) -> 1000x bools (127000B), then handshake.
    ]]
    it("large frame followed by small frame", function(): ()
        local regBig, recvBig = definePacket("__e2e_grow_big", Lync.array(Lync.bool))
        local regSmall, recvSmall = definePacket("__e2e_grow_small", Lync.bool)

        local senderPrev, senderPrevLen: buffer?, number = nil, 0
        local recvPrev, recvPrevLen: buffer?, number = nil, 0

        local big = table.create(1000, true)
        do
            local ch = Channel.create()
            for _ = 1, 100 do
                Channel.writeBatch(ch, regBig, big)
            end
            senderPrev, senderPrevLen, recvPrev, recvPrevLen =
                transmitOneFrame(ch, senderPrev, senderPrevLen, recvPrev, recvPrevLen)
        end

        do
            local ch = Channel.create()
            Channel.writeBatch(ch, regSmall, true)
            senderPrev, senderPrevLen, recvPrev, recvPrevLen =
                transmitOneFrame(ch, senderPrev, senderPrevLen, recvPrev, recvPrevLen)
        end

        expect(#recvBig):toBe(100)
        expect(#recvSmall):toBe(1)
        expect(recvSmall[1]):toBe(true)
    end)

    it("small frame followed by large frame", function(): ()
        local regSmall, recvSmall = definePacket("__e2e_shrink_small", Lync.bool)
        local regBig, recvBig = definePacket("__e2e_shrink_big", Lync.array(Lync.bool))

        local senderPrev, senderPrevLen: buffer?, number = nil, 0
        local recvPrev, recvPrevLen: buffer?, number = nil, 0

        do
            local ch = Channel.create()
            Channel.writeBatch(ch, regSmall, true)
            senderPrev, senderPrevLen, recvPrev, recvPrevLen =
                transmitOneFrame(ch, senderPrev, senderPrevLen, recvPrev, recvPrevLen)
        end

        local big = table.create(1000, true)
        do
            local ch = Channel.create()
            for _ = 1, 100 do
                Channel.writeBatch(ch, regBig, big)
            end
            senderPrev, senderPrevLen, recvPrev, recvPrevLen =
                transmitOneFrame(ch, senderPrev, senderPrevLen, recvPrev, recvPrevLen)
        end

        expect(#recvSmall):toBe(1)
        expect(#recvBig):toBe(100)
    end)
end)

describe("EndToEnd: bench scenario reproduction", function(): ()
    --[[
        Reproduce the exact transition that produced the runtime warning:
        long stream of 1000 BlinkBoolsPackets per frame, then a small
        ServerSwap (1B bool) packet. The bench produced "unknown packet
        ID 31 at byte 0" right at this transition.
    ]]
    it("600 frames of 1000 bools then a single bool packet", function(): ()
        local regBools, recvBools = definePacket("__e2e_bench_swap_bools", Lync.array(Lync.bool))
        local regSwap, recvSwap = definePacket("__e2e_bench_swap_signal", Lync.bool)

        local senderPrev, senderPrevLen: buffer?, number = nil, 0
        local recvPrev, recvPrevLen: buffer?, number = nil, 0

        local data = table.create(1000, true)

        for _ = 1, 600 do
            local ch = Channel.create()
            for _ = 1, 1000 do
                Channel.writeBatch(ch, regBools, data)
            end
            senderPrev, senderPrevLen, recvPrev, recvPrevLen =
                transmitOneFrame(ch, senderPrev, senderPrevLen, recvPrev, recvPrevLen)
        end

        do
            local ch = Channel.create()
            Channel.writeBatch(ch, regSwap, true)
            senderPrev, senderPrevLen, recvPrev, recvPrevLen =
                transmitOneFrame(ch, senderPrev, senderPrevLen, recvPrev, recvPrevLen)
        end

        expect(#recvBools):toBe(600 * 1000)
        expect(#recvSwap):toBe(1)
        expect(recvSwap[1]):toBe(true)
    end)
end)

return nil
