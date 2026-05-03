--!strict
--!optimize 2
-- internal.Middleware: ordered onSend / onReceive / onDrop chains.

local Env = require(script:FindFirstAncestor("test").Env)

local Middleware = Env.Internal.Middleware
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("internal.Middleware", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("onSend chain", function(): ()
        it("transforms data through one hook", function(): ()
            Middleware.onSend(function(d: any): any
                return (d :: number) * 2
            end)
            expect(Middleware.runSend(5, "t", nil)):toBe(10)
        end)
        it("two hooks chain in registration order", function(): ()
            Middleware.onSend(function(d: any): any
                return (d :: number) + 1
            end)
            Middleware.onSend(function(d: any): any
                return (d :: number) * 10
            end)
            expect(Middleware.runSend(5, "t", nil)):toBe(60)
        end)
        it("returning nil keeps the previous value", function(): ()
            Middleware.onSend(function(_d: any): any
                return nil
            end)
            expect(Middleware.runSend(42, "t", nil)):toBe(42)
        end)
        it("disconnect removes the hook", function(): ()
            local conn = Middleware.onSend(function(): any
                return 999
            end)
            conn:disconnect()
            expect(Middleware.runSend(42, "t", nil)):toBe(42)
        end)
        it("hasSendHooks reflects state", function(): ()
            expect(Middleware.hasSendHooks()):toBe(false)
            local conn = Middleware.onSend(function(d: any): any
                return d
            end)
            expect(Middleware.hasSendHooks()):toBe(true)
            conn:disconnect()
            expect(Middleware.hasSendHooks()):toBe(false)
        end)
        it("hooks see name and player args", function(): ()
            local seen: { name: string?, player: any } = { name = nil, player = nil }
            Middleware.onSend(function(d: any, name: string, player: any?): any
                seen.name = name
                seen.player = player
                return d
            end)
            local p = Instance.new("Folder")
            Middleware.runSend(1, "Hit", p)
            expect(seen.name):toBe("Hit")
            expect(seen.player):toBe(p)
            p:Destroy()
        end)
    end)

    describe("onReceive chain", function(): ()
        it("transforms received data", function(): ()
            Middleware.onReceive(function(d: any): any
                return `got: {d}`
            end)
            expect(Middleware.runReceive("hello", "t", nil)):toBe("got: hello")
        end)
        it("hasReceiveHooks reflects state", function(): ()
            expect(Middleware.hasReceiveHooks()):toBe(false)
            local conn = Middleware.onReceive(function(d: any): any
                return d
            end)
            expect(Middleware.hasReceiveHooks()):toBe(true)
            conn:disconnect()
            expect(Middleware.hasReceiveHooks()):toBe(false)
        end)
    end)

    describe("onDrop", function(): ()
        it("fires handler with reason and name", function(): ()
            local got: { reason: string?, name: string? } = { reason = nil, name = nil }
            Middleware.onDrop(function(_p: any, reason: string, name: string): ()
                got.reason = reason
                got.name = name
            end)
            local p = Instance.new("Folder")
            Middleware.fireDrop(p, "rate", "Hit", nil)
            expect(got.reason):toBe("rate")
            expect(got.name):toBe("Hit")
            p:Destroy()
        end)
        it("multiple handlers all fire", function(): ()
            local a, b = 0, 0
            Middleware.onDrop(function(): ()
                a += 1
            end)
            Middleware.onDrop(function(): ()
                b += 1
            end)
            local p = Instance.new("Folder")
            Middleware.fireDrop(p, "t", "n", nil)
            expect(a):toBe(1)
            expect(b):toBe(1)
            p:Destroy()
        end)
    end)

    describe("Sandbox isolation", function(): ()
        it("resetAll drops every hook", function(): ()
            Middleware.onSend(function(d: any): any
                return d
            end)
            Middleware.onReceive(function(d: any): any
                return d
            end)
            Middleware.onDrop(function(): () end)
            Sandbox.resetAll()
            expect(Middleware.hasSendHooks()):toBe(false)
            expect(Middleware.hasReceiveHooks()):toBe(false)
        end)
    end)

    describe("chain depth and ordering", function(): ()
        it("five send hooks all run in order", function(): ()
            local order: { string } = {}
            Middleware.onSend(function(d: any): any
                table.insert(order, "1")
                return d
            end)
            Middleware.onSend(function(d: any): any
                table.insert(order, "2")
                return d
            end)
            Middleware.onSend(function(d: any): any
                table.insert(order, "3")
                return d
            end)
            Middleware.onSend(function(d: any): any
                table.insert(order, "4")
                return d
            end)
            Middleware.onSend(function(d: any): any
                table.insert(order, "5")
                return d
            end)
            Middleware.runSend(0, "t", nil)
            expect(table.concat(order)):toBe("12345")
        end)
        it("disconnecting middle hook preserves earlier and later", function(): ()
            local order: { string } = {}
            Middleware.onSend(function(d: any): any
                table.insert(order, "a")
                return d
            end)
            local mid = Middleware.onSend(function(d: any): any
                table.insert(order, "b")
                return d
            end)
            Middleware.onSend(function(d: any): any
                table.insert(order, "c")
                return d
            end)
            mid:disconnect()
            Middleware.runSend(0, "t", nil)
            expect(table.concat(order)):toBe("ac")
        end)
    end)

    describe("hook errors propagate (no internal pcall)", function(): ()
        --[[
            Middleware.runSend does NOT pcall around hooks. A throwing hook
            kills the chain and surfaces to the caller. Pinning this contract
            so any future change that wraps hooks in pcall breaks the test.
        ]]
        it("error in a hook stops the chain", function(): ()
            local later_ran = false
            Middleware.onSend(function(_d: any): any
                error("boom")
            end)
            Middleware.onSend(function(d: any): any
                later_ran = true
                return d
            end)
            local ok = pcall(function(): ()
                Middleware.runSend(1, "t", nil)
            end)
            expect(ok):toBe(false)
            expect(later_ran):toBe(false)
        end)
    end)

    describe("disconnect idempotency", function(): ()
        it("disconnect twice is safe", function(): ()
            local conn = Middleware.onSend(function(d: any): any
                return d
            end)
            conn:disconnect()
            expect(function(): ()
                conn:disconnect()
            end).never:toThrow()
        end)
        it("connected flag flips on disconnect", function(): ()
            local conn = Middleware.onSend(function(d: any): any
                return d
            end)
            expect(conn.connected):toBe(true)
            conn:disconnect()
            expect(conn.connected):toBe(false)
        end)
    end)

    describe("onDrop with rich payloads", function(): ()
        it("forwards the raw value verbatim", function(): ()
            local got: any = nil
            Middleware.onDrop(function(_p: any, _r: string, _n: string, value: any): ()
                got = value
            end)
            local payload = { hp = 100, items = { "a", "b" } }
            local p = Instance.new("Folder")
            Middleware.fireDrop(p, "rate", "Hit", payload)
            expect(got):toBe(payload)
            p:Destroy()
        end)
        it("disconnect removes drop handler", function(): ()
            local count = 0
            local conn = Middleware.onDrop(function(): ()
                count += 1
            end)
            local p = Instance.new("Folder")
            Middleware.fireDrop(p, "r", "n", nil)
            conn:disconnect()
            Middleware.fireDrop(p, "r", "n", nil)
            expect(count):toBe(1)
            p:Destroy()
        end)
    end)

    describe("send chain transformations", function(): ()
        it("hook returning Lync.DROP is propagated unchanged through chain", function(): ()
            -- Middleware itself doesn't interpret DROP; that's Packet's job.
            -- It just forwards whatever the chain returns.
            local Lync = Env.Lync
            Middleware.onSend(function(_d: any): any
                return Lync.DROP
            end)
            local result = Middleware.runSend(0, "t", nil)
            expect((result :: any)._lyncKind):toBe("drop")
        end)
        it("first nil-returning hook keeps the input value flowing", function(): ()
            Middleware.onSend(function(_d: any): any
                return nil
            end)
            Middleware.onSend(function(d: any): any
                return (d :: number) + 100
            end)
            expect(Middleware.runSend(5, "t", nil)):toBe(105)
        end)
    end)
end)

return nil
