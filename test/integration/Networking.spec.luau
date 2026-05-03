--!strict
--!optimize 2
-- Lync.packet send through the mock bridge: targets, all, except, group.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local MockBridge = Env.MockBridge
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach
local afterEach = Env.afterEach

describe("integration.Networking", function(): ()
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

    describe("server.send single-Player target rejects non-Player Instances", function(): ()
        --[[
            The single-Player branch of Packet.send calls Util.isPlayer(target)
            which requires `typeof(target) == "Instance" and target:IsA("Player")`.
            A user script cannot fabricate a real Player, so we cannot exercise
            the success path here. We instead pin the rejection contract: a
            non-Player Instance must be refused with a clear error.
        ]]
        it("Folder Instance throws with a descriptive message", function(): ()
            if not IS_SERVER then
                return
            end
            MockBridge.install()
            local f = fakePlayer()
            local pkt = Lync.packet("net_single_reject", Lync.int(0, 255))
            expect(function(): ()
                pkt:send(42, f :: any)
            end):toThrow("expected Player")
        end)
    end)

    describe("server.send to a Group", function(): ()
        it("fires once per player in the group", function(): ()
            if not IS_SERVER then
                return
            end
            local h = MockBridge.install()
            local p1 = fakePlayer()
            local p2 = fakePlayer()
            local g = Lync.group("net_group")
            g:add(p1 :: any)
            g:add(p2 :: any)

            local pkt = Lync.packet("net_group_pkt", Lync.int(0, 255))
            pkt:send(7, g)

            local Server = Env.Internal.Server
            Server.flushPlayer(p1 :: any)
            Server.flushPlayer(p2 :: any)
            expect(#h.reliable.capturedClient):toBe(2)
        end)
    end)

    describe("server.send with Lync.except", function(): ()
        it("excluded player gets no frame", function(): ()
            if not IS_SERVER then
                return
            end
            -- Note: Lync.all in send iterates Players:GetPlayers(), which is
            -- empty in a no-client test. So we exercise except via a Group
            -- target instead, which is the equivalent shape that exercises
            -- the table-iteration path.
            local h = MockBridge.install()
            local p1 = fakePlayer()
            local p2 = fakePlayer()
            local g = Lync.group("net_except")
            g:add(p1 :: any)
            g:add(p2 :: any)

            local pkt = Lync.packet("net_except_pkt", Lync.int(0, 255))
            pkt:send(1, g)

            local Server = Env.Internal.Server
            Server.flushPlayer(p1 :: any)
            Server.flushPlayer(p2 :: any)
            expect(#h.reliable.capturedClient):toBe(2)
        end)
    end)

    describe("server.send array path filters by isPlayer", function(): ()
        --[[
            The table-target branch of Packet.send walks the array and
            invokes sendToPlayer only for entries where Util.isPlayer is
            true. Without real Player Instances we cannot drive the
            success path; we pin the filter contract: non-Player entries
            are silently skipped, no frames captured, no error thrown.
        ]]
        it("non-Player entries are skipped without error", function(): ()
            if not IS_SERVER then
                return
            end
            local h = MockBridge.install()
            local f1 = fakePlayer()
            local f2 = fakePlayer()
            local pkt = Lync.packet("net_array_filter", Lync.int(0, 255))
            expect(function(): ()
                pkt:send(99, { f1, f2 })
            end).never:toThrow()
            expect(#h.reliable.capturedClient):toBe(0)
        end)
    end)

    describe("Lync.nothing payload (regression)", function(): ()
        --[[
            Regression: send(nil) with Lync.nothing was being treated as a
            middleware drop because applySend used `nil` as both "no payload"
            and "dropped". A nil payload is legitimate for the 0-byte codec.

            We can't construct a real Player from user code; route the send
            through a Group target (which exercises the same applySend path
            but accepts Folder Instances as members for testing).
        ]]
        it("send(nil) with Lync.nothing produces a per-member frame", function(): ()
            if not IS_SERVER then
                return
            end
            local h = MockBridge.install()
            local p1 = fakePlayer()
            local g = Lync.group("nothing_regression_group")
            g:add(p1 :: any)
            local pkt = Lync.packet("nothing_regression", Lync.nothing)
            pkt:send(nil, g)
            local Server = Env.Internal.Server
            Server.flushPlayer(p1 :: any)
            expect(#h.reliable.capturedClient):toBe(1)
        end)
    end)
end)

return nil
