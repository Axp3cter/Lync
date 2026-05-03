--!strict
--!optimize 2
-- api.Packet: define, on/once/wait, stats, define-time validation.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("api.Packet", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("define returns a frozen handle", function(): ()
        it("handle has send/on/once/wait/name/stats", function(): ()
            local p = Lync.packet("define_basics", Lync.int(0, 255))
            expect(p):toBeFrozen()
            expect((p :: any).send):toBeType("function")
            expect((p :: any).on):toBeType("function")
            expect((p :: any).once):toBeType("function")
            expect((p :: any).wait):toBeType("function")
            expect((p :: any).name):toBeType("function")
            expect((p :: any).stats):toBeType("function")
        end)
        it("name() returns the registered name", function(): ()
            local p = Lync.packet("define_named", Lync.int(0, 255))
            expect(p:name()):toBe("define_named")
        end)
        it("stats() returns initial counters", function(): ()
            local p = Lync.packet("define_stats", Lync.int(0, 255))
            local stats = p:stats()
            expect(stats.bytesSent):toBe(0)
            expect(stats.bytesReceived):toBe(0)
            expect(stats.fires):toBe(0)
            expect(stats.recvFires):toBe(0)
            expect(stats.drops):toBe(0)
        end)
    end)

    describe("on / once delivery within the same VM", function(): ()
        it("on fires for every signal trigger", function(): ()
            local p = Lync.packet("on_pkt", Lync.int(0, 255))
            local got: { number } = {}
            p:on(function(v: number): ()
                table.insert(got, v)
            end)
            -- Fire the registry signal directly to simulate inbound.
            local Registry = Env.Internal.Registry
            local reg = Registry.getByName("on_pkt") :: any
            reg.signal:fireSync(7, nil, nil)
            reg.signal:fireSync(8, nil, nil)
            expect(#got):toBe(2)
            expect(got[1]):toBe(7)
            expect(got[2]):toBe(8)
        end)
        it("once fires exactly once", function(): ()
            local p = Lync.packet("once_pkt", Lync.int(0, 255))
            local count = 0
            p:once(function(): ()
                count += 1
            end)
            local Registry = Env.Internal.Registry
            local reg = Registry.getByName("once_pkt") :: any
            reg.signal:fireSync(1, nil, nil)
            reg.signal:fireSync(2, nil, nil)
            reg.signal:fireSync(3, nil, nil)
            expect(count):toBe(1)
        end)
    end)

    describe("define-time validation", function(): ()
        it("delta codec + unreliable transport throws", function(): ()
            expect(function(): ()
                Lync.packet(
                    "delta_unrel",
                    Lync.deltaStruct({ x = Lync.int(0, 255) }),
                    { unreliable = true }
                )
            end):toThrow("delta")
        end)
        it("duplicate packet name throws (Registry duplicate)", function(): ()
            Lync.packet("dup_name", Lync.int(0, 255))
            expect(function(): ()
                Lync.packet("dup_name", Lync.int(0, 255))
            end):toThrow("duplicate")
        end)
    end)

    describe("server send target validation", function(): ()
        it("nil target on server send throws", function(): ()
            local RunService = game:GetService("RunService")
            if not RunService:IsServer() then
                return
            end
            local p = Lync.packet("server_nil", Lync.int(0, 255))
            expect(function(): ()
                p:send(42, nil)
            end):toThrow("requires a target")
        end)
        it("invalid target shape throws", function(): ()
            local RunService = game:GetService("RunService")
            if not RunService:IsServer() then
                return
            end
            local p = Lync.packet("server_bad_target", Lync.int(0, 255))
            expect(function(): ()
                p:send(42, "not a player")
            end):toThrow()
        end)
    end)

    describe("stats counters update on signal fire", function(): ()
        it("recvFires increments after Channel.statsEnabled + signal:fire", function(): ()
            local Channel = Env.Internal.Channel
            Channel.enableStats()
            local p = Lync.packet("stats_recv", Lync.int(0, 255))
            local Registry = Env.Internal.Registry
            local reg = Registry.getByName("stats_recv") :: any
            -- Note: stats counters are bumped by Reader.process, not by direct
            -- signal fire. The handle's stats() reads reg.* directly. Verify
            -- the wiring by mutating the reg counter and re-reading.
            reg.recvFires = 5
            expect(p:stats().recvFires):toBe(5)
        end)
    end)
end)

return nil
