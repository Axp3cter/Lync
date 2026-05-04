--!strict
--!optimize 2
-- Broadcast encode-once: verify per-player channels receive identical payload bytes.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local MockBridge = Env.MockBridge
local Sandbox = Env.Sandbox
local Server = Env.Internal.Server

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach
local afterEach = Env.afterEach

local RunService = game:GetService("RunService")
local IS_SERVER = RunService:IsServer()

describe("integration.Broadcast", function(): ()
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

    --[[
        Compare per-player reliable channel cursor sizes — encode-once must
        produce identical byte counts across receivers since the codec output
        is stateless. Per-player XOR baselines diverge AFTER channel writes,
        but the writeBatch call writes the same scratch bytes.
    ]]
    describe("encode-once for non-delta codecs", function(): ()
        it("each player's channel grows by the same byte count", function(): ()
            if not IS_SERVER then
                return
            end
            MockBridge.install()
            local players = {}
            for _ = 1, 4 do
                local p = fakePlayer()
                table.insert(players, p)
                Server.getChannel(p :: any, false)
            end

            local g = Lync.group("bcast_encode_once_grp")
            for _, p in players do
                g:add(p :: any)
            end

            local pkt = Lync.packet("bcast_encode_once", Lync.int(0, 65535))
            pkt:send(0xAABB, g)

            local cursors = {}
            for i, p in players do
                cursors[i] = Server.getChannel(p :: any, false).cursor
            end
            for i = 2, #cursors do
                expect(cursors[i]):toBe(cursors[1])
            end
        end)
        it("each player's channel sees byte-identical payload", function(): ()
            if not IS_SERVER then
                return
            end
            MockBridge.install()
            local players = {}
            for _ = 1, 3 do
                local p = fakePlayer()
                table.insert(players, p)
                Server.getChannel(p :: any, false)
            end
            local g = Lync.group("bcast_byte_eq_grp")
            for _, p in players do
                g:add(p :: any)
            end

            local pkt = Lync.packet("bcast_byte_eq", Lync.string)
            pkt:send("hello world", g)

            local channels = {}
            for i, p in players do
                channels[i] = Server.getChannel(p :: any, false)
            end
            local len = channels[1].cursor
            for i = 2, #channels do
                expect(channels[i].cursor):toBe(len)
                for j = 0, len - 1 do
                    expect(buffer.readu8(channels[i].buff, j)):toBe(
                        buffer.readu8(channels[1].buff, j)
                    )
                end
            end
        end)
    end)

    describe("delta codecs fall through to per-player encode", function(): ()
        --[[
            For delta codecs the per-receiver state diverges, so each player's
            channel must run the codec.write independently. This test only
            asserts correctness — that every player receives a valid payload —
            since the underlying caches are now independent.
        ]]
        it("deltaInt to all players writes per-player bytes", function(): ()
            if not IS_SERVER then
                return
            end
            MockBridge.install()
            local players = {}
            for _ = 1, 3 do
                local p = fakePlayer()
                table.insert(players, p)
                Server.getChannel(p :: any, false)
            end
            local g = Lync.group("bcast_delta_grp")
            for _, p in players do
                g:add(p :: any)
            end

            local pkt = Lync.packet("bcast_delta", Lync.deltaInt(0, 1000))
            pkt:send(500, g)

            for _, p in players do
                expect(Server.getChannel(p :: any, false).cursor):toBeGreaterThan(0)
            end
        end)
    end)

    describe("ref-bearing codecs fall through to per-player path", function(): ()
        it("Lync.unknown to multiple players still works via fallback", function(): ()
            if not IS_SERVER then
                return
            end
            MockBridge.install()
            local players = {}
            for _ = 1, 3 do
                local p = fakePlayer()
                table.insert(players, p)
                Server.getChannel(p :: any, false)
            end
            local g = Lync.group("bcast_unknown_grp")
            for _, p in players do
                g:add(p :: any)
            end

            local pkt = Lync.packet("bcast_unknown", Lync.unknown, {
                validate = function(_: any, _: Player): (boolean, string?)
                    return true, nil
                end,
            })
            local sentinel = fakePlayer()
            pkt:send(sentinel :: any, g)

            for _, p in players do
                local ch = Server.getChannel(p :: any, false)
                expect(ch.cursor):toBeGreaterThan(0)
                expect(ch.refCount):toBeGreaterThan(0)
            end
        end)
    end)

    describe("encode-once selects the right reliability getter", function(): ()
        -- Packet.broadcast pre-resolves getReliableChannel vs getUnreliableChannel
        -- based on isUnreliable. Each side must populate only its own channel map.
        it("reliable broadcast writes only to reliable channels", function(): ()
            if not IS_SERVER then
                return
            end
            MockBridge.install()
            local players = {}
            for _ = 1, 3 do
                local p = fakePlayer()
                table.insert(players, p)
                Server.getChannel(p :: any, false)
                Server.getChannel(p :: any, true)
            end
            local g = Lync.group("bcast_rel_grp")
            for _, p in players do
                g:add(p :: any)
            end
            local pkt = Lync.packet("bcast_rel_only", Lync.int(0, 255))
            pkt:send(7, g)
            for _, p in players do
                expect(Server.getChannel(p :: any, false).cursor):toBeGreaterThan(0)
                expect(Server.getChannel(p :: any, true).cursor):toBe(0)
            end
        end)
        it("unreliable broadcast writes only to unreliable channels", function(): ()
            if not IS_SERVER then
                return
            end
            MockBridge.install()
            local players = {}
            for _ = 1, 3 do
                local p = fakePlayer()
                table.insert(players, p)
                Server.getChannel(p :: any, false)
                Server.getChannel(p :: any, true)
            end
            local g = Lync.group("bcast_unrel_grp")
            for _, p in players do
                g:add(p :: any)
            end
            local pkt = Lync.packet("bcast_unrel_only", Lync.int(0, 255), { unreliable = true })
            pkt:send(7, g)
            for _, p in players do
                expect(Server.getChannel(p :: any, true).cursor):toBeGreaterThan(0)
                expect(Server.getChannel(p :: any, false).cursor):toBe(0)
            end
        end)
    end)

    describe("targets routing", function(): ()
        it("Lync.all routes via broadcast without throwing on empty Players service", function(): ()
            if not IS_SERVER then
                return
            end
            MockBridge.install()
            local pkt = Lync.packet("bcast_all_smoke", Lync.int(0, 255))
            expect(function(): ()
                pkt:send(1, Lync.all)
            end).never:toThrow()
        end)
        it("Lync.except builder rejects non-Player non-Group args", function(): ()
            expect(function(): ()
                Lync.except("not a player" :: any)
            end):toThrow("Player or Group")
        end)
        it("Lync.except() with no args returns a valid sentinel", function(): ()
            expect(function(): ()
                local _: any = Lync.except()
            end).never:toThrow()
        end)
        --[[
            The plain { Player } array path filters via isPlayer (which checks
            typeof == "Instance" and IsA("Player")) — fakeplayer Folders fail
            that gate, so a unit test for the array path would broadcast to
            an empty list. The group send test in Multiplayer.spec exercises
            the same fanout once isPlayer accepts the entries.
        ]]
    end)
end)

return nil
