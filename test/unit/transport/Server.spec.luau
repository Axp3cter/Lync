--!strict
--!optimize 2
-- transport.Server: per-player channel acquire, getChannel, stats.

local Env = require(script:FindFirstAncestor("test").Env)

local MockBridge = Env.MockBridge
local Sandbox = Env.Sandbox
local Server = Env.Internal.Server

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach
local afterEach = Env.afterEach

describe("transport.Server", function(): ()
    local instances: { Instance } = {}

    beforeEach(function(): ()
        Sandbox.resetAll()
        table.clear(instances)
    end)

    afterEach(function(): ()
        for _, inst in instances do
            inst:Destroy()
        end
        table.clear(instances)
    end)

    local function fakePlayer(): Instance
        local f = Instance.new("Folder")
        table.insert(instances, f)
        return f
    end

    describe("getChannel", function(): ()
        it("returns the same channel for the same player + reliability", function(): ()
            local p = fakePlayer()
            local a = Server.getChannel(p :: any, false)
            local b = Server.getChannel(p :: any, false)
            expect(a):toBe(b)
        end)
        it("reliable and unreliable channels are distinct", function(): ()
            local p = fakePlayer()
            expect(Server.getChannel(p :: any, false)).never:toBe(Server.getChannel(p :: any, true))
        end)
        it("different players get distinct channels", function(): ()
            local p1 = fakePlayer()
            local p2 = fakePlayer()
            expect(Server.getChannel(p1 :: any, false)).never:toBe(
                Server.getChannel(p2 :: any, false)
            )
        end)
    end)

    describe("pre-resolved channel getters (broadcast hot path)", function(): ()
        -- Packet.broadcast captures one of these once and calls it per audience
        -- member, eliminating a per-call branch on isUnreliable.
        it("getReliableChannel matches getChannel(_, false)", function(): ()
            local p = fakePlayer()
            expect(Server.getReliableChannel(p :: any)):toBe(Server.getChannel(p :: any, false))
        end)
        it("getUnreliableChannel matches getChannel(_, true)", function(): ()
            local p = fakePlayer()
            expect(Server.getUnreliableChannel(p :: any)):toBe(Server.getChannel(p :: any, true))
        end)
        it("reliable and unreliable getters return distinct channels", function(): ()
            local p = fakePlayer()
            expect(Server.getReliableChannel(p :: any)).never:toBe(
                Server.getUnreliableChannel(p :: any)
            )
        end)
        it("acquire-on-miss: first call materializes a fresh channel", function(): ()
            local p = fakePlayer()
            local ch = Server.getReliableChannel(p :: any)
            expect(ch.cursor):toBe(0)
            expect(ch.size):toBeGreaterThan(0)
        end)
    end)

    describe("flush is a no-op when channels have no data", function(): ()
        it("does not throw with mock bridge installed", function(): ()
            MockBridge.install()
            expect(function(): ()
                Server.flush()
            end).never:toThrow()
        end)
    end)

    describe("player stats", function(): ()
        it("getPlayerStats returns nil before stats enabled", function(): ()
            local p = fakePlayer()
            expect(Server.getPlayerStats(p :: any)):toBeNil()
        end)
        it("resetStats does not throw", function(): ()
            expect(function(): ()
                Server.resetStats()
            end).never:toThrow()
        end)
    end)

    describe("flushPlayer per-player isolation", function(): ()
        it("flushPlayer with no data does not throw", function(): ()
            MockBridge.install()
            local p = fakePlayer()
            expect(function(): ()
                Server.flushPlayer(p :: any)
            end).never:toThrow()
        end)
        it("flushPlayer for one player leaves another player's channel intact", function(): ()
            MockBridge.install()
            local Lync = Env.Lync
            local Channel = Env.Internal.Channel
            local Registry = Env.Internal.Registry
            local p1 = fakePlayer()
            local p2 = fakePlayer()
            local reg = Registry.register({
                name = "srv_isolate",
                kind = Registry.KIND_PACKET,
                codec = Lync.int(0, 255),
                isUnreliable = false,
                partner = nil,
                needsGate = false,
                headerSize = 1,
                timestampMode = Channel.TS_NONE,
                openFn = Channel.resolveOpenFn(Channel.TS_NONE, "srv_isolate"),
                rateLimit = nil,
                validate = nil,
                maxPayloadBytes = nil,
            })
            local ch1 = Server.getChannel(p1 :: any, false)
            local ch2 = Server.getChannel(p2 :: any, false)
            Channel.writeBatch(ch1, reg, 1)
            Channel.writeBatch(ch2, reg, 2)
            Server.flushPlayer(p1 :: any)
            expect(ch1.cursor):toBe(0)
            expect(ch2.cursor):toBeGreaterThan(0)
        end)
    end)

    --[[
        Notes on what is NOT tested here:

        Server.clearPlayer does not exist as a public method (the cleanup
        runs through the private Players.PlayerRemoving handler installed
        by Server.start). And Server.flush walks Players:GetPlayers(),
        which is empty in the unit-test sandbox. flushPlayer per-player
        is the directly testable surface; covered above.
    ]]
end)

return nil
