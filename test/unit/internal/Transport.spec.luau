--!strict
--!optimize 2
-- internal.Transport: lazy-require shim that breaks the api -> transport cycle.

local Env = require(script:FindFirstAncestor("test").Env)

local Sandbox = Env.Sandbox
local Transport = Env.Internal.Transport

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("internal.Transport", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("server() returns the Server module", function(): ()
        it("exposes flush", function(): ()
            local srv = Transport.server()
            expect(srv.flush):toBeType("function")
        end)
        it("exposes getChannel", function(): ()
            local srv = Transport.server()
            expect(srv.getChannel):toBeType("function")
        end)
        it("memoizes on subsequent calls", function(): ()
            expect(Transport.server()):toBe(Transport.server())
        end)
    end)

    describe("client() returns the Client module", function(): ()
        it("exposes flush", function(): ()
            local cli = Transport.client()
            expect(cli.flush):toBeType("function")
        end)
        it("exposes getChannel", function(): ()
            local cli = Transport.client()
            expect(cli.getChannel):toBeType("function")
        end)
        it("memoizes on subsequent calls", function(): ()
            expect(Transport.client()):toBe(Transport.client())
        end)
    end)

    describe("module surface guarantees", function(): ()
        it("Transport itself is frozen", function(): ()
            expect(Transport):toBeFrozen()
        end)
        it("server() result has at least flush, getChannel, flushPlayer", function(): ()
            local srv = Transport.server() :: any
            expect(srv.flush):toBeType("function")
            expect(srv.getChannel):toBeType("function")
            expect(srv.flushPlayer):toBeType("function")
        end)
        it("client() result has at least flush, getChannel", function(): ()
            local cli = Transport.client() :: any
            expect(cli.flush):toBeType("function")
            expect(cli.getChannel):toBeType("function")
        end)
    end)

    describe("server vs client are distinct objects", function(): ()
        it("Transport.server() != Transport.client()", function(): ()
            expect(Transport.server()).never:toBe(Transport.client())
        end)
    end)

    describe("call across sandbox reset", function(): ()
        it("server() returns the same module after Sandbox.resetAll", function(): ()
            local before = Transport.server()
            Sandbox.resetAll()
            local after = Transport.server()
            expect(before):toBe(after)
        end)
    end)
end)

return nil
