--!strict
--!optimize 2
-- End-to-end pipeline: write -> seal -> xor encode -> xor decode -> Reader.

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

local function definePacket(name: string, codec: any): (any, { any })
    local received: { any } = {}
    local handle = Lync.packet(name, codec)
    handle:on(function(value: any): ()
        table.insert(received, value)
    end)
    return Registry.getByName(name), received
end

--[[
    Simulate one wire transmission. Returns updated baselines for both
    sides so successive calls maintain the XOR delta chain.
]]
local function transmit(
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

describe("integration.Pipeline", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("identical-content frames stay decoded across XOR delta", function(): ()
        it("3 frames of the same u8 packet", function(): ()
            local reg, received = definePacket("p_same_u8", Lync.int(0, 255))
            local sP: buffer?, sL = nil, 0
            local rP: buffer?, rL = nil, 0
            for _ = 1, 3 do
                local ch = Channel.create()
                Channel.writeBatch(ch, reg, 42)
                sP, sL, rP, rL = transmit(ch, sP, sL, rP, rL)
            end
            expect(#received):toBe(3)
            expect(received[1]):toBe(42)
            expect(received[2]):toBe(42)
            expect(received[3]):toBe(42)
        end)
    end)

    describe("frame-size transitions across XOR delta", function(): ()
        it("large then small", function(): ()
            local regBig, recvBig = definePacket("p_grow_big", Lync.array(Lync.bool))
            local regSmall, recvSmall = definePacket("p_grow_small", Lync.bool)
            local sP: buffer?, sL = nil, 0
            local rP: buffer?, rL = nil, 0

            local big = table.create(1000, true)
            do
                local ch = Channel.create()
                for _ = 1, 100 do
                    Channel.writeBatch(ch, regBig, big)
                end
                sP, sL, rP, rL = transmit(ch, sP, sL, rP, rL)
            end

            do
                local ch = Channel.create()
                Channel.writeBatch(ch, regSmall, true)
                sP, sL, rP, rL = transmit(ch, sP, sL, rP, rL)
            end

            expect(#recvBig):toBe(100)
            expect(#recvSmall):toBe(1)
            expect(recvSmall[1]):toBe(true)
        end)
        it("small then large", function(): ()
            local regSmall, recvSmall = definePacket("p_shrink_small", Lync.bool)
            local regBig, recvBig = definePacket("p_shrink_big", Lync.array(Lync.bool))
            local sP: buffer?, sL = nil, 0
            local rP: buffer?, rL = nil, 0

            do
                local ch = Channel.create()
                Channel.writeBatch(ch, regSmall, true)
                sP, sL, rP, rL = transmit(ch, sP, sL, rP, rL)
            end

            local big = table.create(1000, true)
            do
                local ch = Channel.create()
                for _ = 1, 100 do
                    Channel.writeBatch(ch, regBig, big)
                end
                sP, sL, rP, rL = transmit(ch, sP, sL, rP, rL)
            end

            expect(#recvSmall):toBe(1)
            expect(#recvBig):toBe(100)
        end)
    end)

    describe("bench-shape stress", function(): ()
        it("5 frames of 1000 fires of array(bool, 1000)", function(): ()
            local reg, received = definePacket("p_bench_bools", Lync.array(Lync.bool))
            local data = table.create(1000, true)
            local sP: buffer?, sL = nil, 0
            local rP: buffer?, rL = nil, 0
            for _ = 1, 5 do
                local ch = Channel.create()
                for _ = 1, 1000 do
                    Channel.writeBatch(ch, reg, data)
                end
                sP, sL, rP, rL = transmit(ch, sP, sL, rP, rL)
                task.wait()
            end
            expect(#received):toBe(5000)
            expect(#received[5000]):toBe(1000)
        end)
        it("5 frames of 400 fires of array(struct(6xu8), 100)", function(): ()
            local entityCodec = Lync.struct({
                id = Lync.int(0, 255),
                x = Lync.int(0, 255),
                y = Lync.int(0, 255),
                z = Lync.int(0, 255),
                orientation = Lync.int(0, 255),
                animation = Lync.int(0, 255),
            })
            local reg, received = definePacket("p_bench_entities", Lync.array(entityCodec))
            local entity = { id = 1, x = 2, y = 3, z = 4, orientation = 5, animation = 6 }
            local data = table.create(100, entity)
            local sP: buffer?, sL = nil, 0
            local rP: buffer?, rL = nil, 0
            for _ = 1, 5 do
                local ch = Channel.create()
                for _ = 1, 400 do
                    Channel.writeBatch(ch, reg, data)
                end
                sP, sL, rP, rL = transmit(ch, sP, sL, rP, rL)
                task.wait()
            end
            expect(#received):toBe(2000)
            expect(received[2000][100].animation):toBe(6)
        end)
    end)

    describe("transition regression", function(): ()
        it("600 frames of 1000 bools then a single bool packet", function(): ()
            local regBools, recvBools = definePacket("p_swap_bools", Lync.array(Lync.bool))
            local regSwap, recvSwap = definePacket("p_swap_signal", Lync.bool)
            local data = table.create(1000, true)
            local sP: buffer?, sL = nil, 0
            local rP: buffer?, rL = nil, 0

            for f = 1, 600 do
                local ch = Channel.create()
                for _ = 1, 1000 do
                    Channel.writeBatch(ch, regBools, data)
                end
                sP, sL, rP, rL = transmit(ch, sP, sL, rP, rL)
                -- Yield every iteration: 600 transmits at ~16ms each is fine,
                -- but 600 sequential without yield is far over the 10s budget.
                if f % 5 == 0 then
                    task.wait()
                end
            end

            do
                local ch = Channel.create()
                Channel.writeBatch(ch, regSwap, true)
                sP, sL, rP, rL = transmit(ch, sP, sL, rP, rL)
            end

            expect(#recvBools):toBe(600 * 1000)
            expect(#recvSwap):toBe(1)
            expect(recvSwap[1]):toBe(true)
        end)
    end)
end)

return nil
