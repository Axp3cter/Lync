--!strict
--!optimize 2
-- Multi-player baseline isolation through Server channels and Baseline cache.

local Env = require(script:FindFirstAncestor("test").Env)

local Baseline = Env.Internal.Baseline
local Lync = Env.Lync
local MockBridge = Env.MockBridge
local Sandbox = Env.Sandbox
local Server = Env.Internal.Server

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach
local afterEach = Env.afterEach

describe("integration.Multiplayer", function(): ()
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

    local RunService = game:GetService("RunService")
    local IS_SERVER = RunService:IsServer()

    describe("each player has independent channel state", function(): ()
        it("getChannel returns a different ChannelState per player", function(): ()
            if not IS_SERVER then
                return
            end
            local p1 = fakePlayer()
            local p2 = fakePlayer()
            local p3 = fakePlayer()
            local p4 = fakePlayer()
            local channels = {
                Server.getChannel(p1 :: any, false),
                Server.getChannel(p2 :: any, false),
                Server.getChannel(p3 :: any, false),
                Server.getChannel(p4 :: any, false),
            }
            for i = 1, 4 do
                for j = i + 1, 4 do
                    expect(channels[i]).never:toBe(channels[j])
                end
            end
        end)
    end)

    describe("Baseline isolation by player", function(): ()
        it("each player's delta cache is independent", function(): ()
            local p1 = fakePlayer()
            local p2 = fakePlayer()
            Baseline.setReadKey(p1)
            Baseline.setCache(1, "a")
            Baseline.setReadKey(p2)
            Baseline.setCache(1, "b")
            Baseline.setReadKey(p1)
            expect(Baseline.getCache(1)):toBe("a")
            Baseline.setReadKey(p2)
            expect(Baseline.getCache(1)):toBe("b")
        end)
    end)

    describe("group send fires per-player", function(): ()
        it("4 players in a group each receive a frame", function(): ()
            if not IS_SERVER then
                return
            end
            local h = MockBridge.install()
            local players = {} :: { Instance }
            local g = Lync.group("mp_group")
            for _ = 1, 4 do
                local p = fakePlayer()
                table.insert(players, p)
                g:add(p :: any)
            end
            local pkt = Lync.packet("mp_send", Lync.int(0, 255))
            pkt:send(123, g)
            for _, p in players do
                Server.flushPlayer(p :: any)
            end
            expect(#h.reliable.capturedClient):toBe(4)
        end)
    end)

    describe("clearPlayer fully isolates removed player", function(): ()
        it("baseline cache cleared after Baseline.clearPlayer", function(): ()
            local p = fakePlayer()
            Baseline.setReadKey(p)
            Baseline.setCache(7, "data")
            Baseline.clearPlayer(p)
            Baseline.setReadKey(p)
            expect(Baseline.getCache(7)):toBeNil()
        end)
    end)

    describe("send to one player does not pollute another's channel", function(): ()
        it("p1 receives, p2 channel cursor stays 0", function(): ()
            if not IS_SERVER then
                return
            end
            MockBridge.install()
            local Channel = Env.Internal.Channel
            local Registry = Env.Internal.Registry
            local p1 = fakePlayer()
            local p2 = fakePlayer()
            local reg = Registry.register({
                name = "mp_isolate",
                kind = Registry.KIND_PACKET,
                codec = Lync.int(0, 255),
                isUnreliable = false,
                partner = nil,
                needsGate = false,
                headerSize = 1,
                timestampMode = Channel.TS_NONE,
                openFn = Channel.resolveOpenFn(Channel.TS_NONE, "mp_isolate"),
                rateLimit = nil,
                validate = nil,
                maxPayloadBytes = nil,
            })
            Channel.writeBatch(Server.getChannel(p1 :: any, false), reg, 1)
            expect(Server.getChannel(p2 :: any, false).cursor):toBe(0)
        end)
    end)

    describe("group send semantics", function(): ()
        it("group iteration order is implementation-defined but stable", function(): ()
            if not IS_SERVER then
                return
            end
            local g = Lync.group("mp_iter")
            local p1 = fakePlayer()
            local p2 = fakePlayer()
            g:add(p1 :: any)
            g:add(p2 :: any)
            local first: { any } = {}
            for p in g do
                table.insert(first, p)
            end
            local second: { any } = {}
            for p in g do
                table.insert(second, p)
            end
            expect(#first):toBe(#second)
        end)
        it("group send to empty group is a no-op", function(): ()
            if not IS_SERVER then
                return
            end
            local h = MockBridge.install()
            local g = Lync.group("mp_empty")
            local pkt = Lync.packet("mp_empty_pkt", Lync.int(0, 255))
            expect(function(): ()
                pkt:send(1, g)
            end).never:toThrow()
            expect(#h.reliable.capturedClient):toBe(0)
        end)
    end)

    describe("Lync.except (target builder)", function(): ()
        --[[
            Lync.except requires Player or Group args. Unit tests can't
            create real Player Instances, so the positive path uses a
            Group as the exclusion source. The Player-arg path is covered
            indirectly by integration runs against actual Players.
        ]]
        it('except(group) returns a frozen sentinel branded "except"', function(): ()
            local g = Lync.group("mp_except_src")
            local p1 = fakePlayer()
            g:add(p1 :: any)
            local exc = Lync.except(g)
            expect((exc :: any)._lyncKind):toBe("except")
            expect(exc):toBeFrozen()
        end)
        it("except's _excluded set covers every member of the source group", function(): ()
            local g = Lync.group("mp_except_members")
            local p1 = fakePlayer()
            local p2 = fakePlayer()
            g:add(p1 :: any)
            g:add(p2 :: any)
            local exc = Lync.except(g)
            local excluded = (exc :: any)._excluded :: { [Instance]: boolean }
            expect(excluded[p1 :: any]):toBe(true)
            expect(excluded[p2 :: any]):toBe(true)
        end)
        it("except rejects non-Player non-Group args", function(): ()
            local f = fakePlayer()
            expect(function(): ()
                Lync.except(f :: any)
            end):toThrow("Player or Group")
        end)
    end)

    describe("delta cache is per-player, not global", function(): ()
        it("p1 receives FULL frame on first delta packet, p2 also gets FULL", function(): ()
            local p1 = fakePlayer()
            local p2 = fakePlayer()
            local c = Lync.deltaStruct({ hp = Lync.int(0, 1000) })
            local Channel = Env.Internal.Channel

            -- p1 path
            Baseline.setReadKey(p1)
            local ch1 = Channel.create()
            c.write(ch1, { hp = 100 })
            local first1 = ch1.cursor
            -- p2 first time also full-encoding
            Baseline.setReadKey(p2)
            local ch2 = Channel.create()
            c.write(ch2, { hp = 100 })
            local first2 = ch2.cursor

            -- Both first writes for distinct read-keys should be > 1 byte (FULL).
            expect(first1 > 1):toBe(true)
            expect(first2 > 1):toBe(true)
        end)
    end)
end)

return nil
