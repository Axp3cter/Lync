--!strict
--!optimize 2
-- api.Query: define, handle (single-active), stats, request validation.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Registry = Env.Internal.Registry
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("api.Query", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("define returns a frozen handle", function(): ()
        it("handle exposes handle/request/name/stats", function(): ()
            local q = Lync.query("q_basic", Lync.int(0, 255), Lync.string)
            expect(q):toBeFrozen()
            expect((q :: any).handle):toBeType("function")
            expect((q :: any).request):toBeType("function")
            expect((q :: any).name):toBeType("function")
            expect((q :: any).stats):toBeType("function")
        end)
        it("name returns the user-facing name", function(): ()
            local q = Lync.query("q_named", Lync.int(0, 255), Lync.string)
            expect(q:name()):toBe("q_named")
        end)
        it("registers two registrations: request + response", function(): ()
            local before = Registry.count()
            Lync.query("q_two", Lync.int(0, 255), Lync.string)
            expect(Registry.count() - before):toBe(2)
        end)
        it("response registration has KIND_RESPONSE and is partnered", function(): ()
            Lync.query("q_partner", Lync.int(0, 255), Lync.string)
            local req = Registry.getByName("q_partner") :: any
            expect(req.kind):toBe(Registry.KIND_REQUEST)
            local resp = Registry.get(req.partner :: number) :: any
            expect(resp.kind):toBe(Registry.KIND_RESPONSE)
            expect(resp.partner):toBe(req.id)
        end)
    end)

    describe("handle replaces an active handler", function(): ()
        it("only the latest handler dispatches", function(): ()
            local q = Lync.query("q_replace", Lync.int(0, 255), Lync.int(0, 255))
            local hits = { a = 0, b = 0 }
            local connA = q:handle(function(_d: any, _p: any): any
                hits.a += 1
                return 1
            end)
            q:handle(function(_d: any, _p: any): any
                hits.b += 1
                return 2
            end)

            -- Fire the request signal directly to simulate inbound dispatch.
            local req = Registry.getByName("q_replace") :: any
            req.signal:fireSync(0, nil, 1)
            expect(hits.a):toBe(0)
            expect(hits.b):toBe(1)

            -- After disconnecting the second, handler is cleared.
            connA:disconnect()
        end)
        it("handler can be disconnected; later requests have no responder", function(): ()
            local q = Lync.query("q_disc", Lync.int(0, 255), Lync.int(0, 255))
            local count = 0
            local conn = q:handle(function(): any
                count += 1
                return 0
            end)
            local req = Registry.getByName("q_disc") :: any
            req.signal:fireSync(0, nil, 1)
            expect(count):toBe(1)
            conn:disconnect()
            -- Subsequent fires no longer reach the handler.
            req.signal:fireSync(0, nil, 2)
            expect(count):toBe(1)
        end)
    end)

    describe("stats", function(): ()
        it("aggregates request + response counters", function(): ()
            local q = Lync.query("q_stats", Lync.int(0, 255), Lync.string)
            local req = Registry.getByName("q_stats") :: any
            local resp = Registry.get(req.partner :: number) :: any
            req.bytesReceived = 10
            resp.bytesReceived = 5
            local s = q:stats()
            expect(s.bytesReceived):toBe(15)
        end)
    end)

    describe("server-side request requires target", function(): ()
        it("nil target throws", function(): ()
            local RunService = game:GetService("RunService")
            if not RunService:IsServer() then
                return
            end
            local q = Lync.query("q_server_nil", Lync.int(0, 255), Lync.string)
            expect(function(): ()
                q:request(42, nil)
            end):toThrow("requires a target")
        end)
    end)

    describe("define-time uniqueness", function(): ()
        it("duplicate query name throws (registry collision)", function(): ()
            Lync.query("q_dup", Lync.int(0, 255), Lync.string)
            expect(function(): ()
                Lync.query("q_dup", Lync.int(0, 255), Lync.string)
            end):toThrow("duplicate")
        end)
    end)

    describe("response codec is registered with embedded suffix", function(): ()
        it("response reg's name has the \\0resp suffix", function(): ()
            Lync.query("q_suffix", Lync.int(0, 255), Lync.string)
            local req = Registry.getByName("q_suffix") :: any
            local resp = Registry.get(req.partner :: number) :: any
            expect(resp.name):toBe("q_suffix\0resp")
        end)
        it("by-name lookup excludes response (only request indexed)", function(): ()
            Lync.query("q_byname", Lync.int(0, 255), Lync.string)
            expect(Registry.getByName("q_byname\0resp")):toBeNil()
        end)
    end)

    describe("stats counters across response", function(): ()
        it("stats sums request.fires + response.fires", function(): ()
            local q = Lync.query("q_fires", Lync.int(0, 255), Lync.string)
            local req = Registry.getByName("q_fires") :: any
            local resp = Registry.get(req.partner :: number) :: any
            req.fires = 7
            resp.fires = 11
            expect(q:stats().fires):toBe(18)
        end)
        it("stats sums recvFires across both regs", function(): ()
            local q = Lync.query("q_recv", Lync.int(0, 255), Lync.string)
            local req = Registry.getByName("q_recv") :: any
            local resp = Registry.get(req.partner :: number) :: any
            req.recvFires = 1
            resp.recvFires = 2
            expect(q:stats().recvFires):toBe(3)
        end)
        it("stats sums drops across both regs", function(): ()
            local q = Lync.query("q_drops", Lync.int(0, 255), Lync.string)
            local req = Registry.getByName("q_drops") :: any
            local resp = Registry.get(req.partner :: number) :: any
            req.drops = 3
            resp.drops = 4
            expect(q:stats().drops):toBe(7)
        end)
    end)
end)

return nil
