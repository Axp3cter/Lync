--!strict
--!optimize 2
local Middleware = require(script.Parent.Parent.Parent.internal.Middleware)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe("Middleware: onSend chain", function(): ()
    it("transforms data", function(): ()
        local c = Middleware.onSend(function(d: any): any
            return (d :: number) * 2
        end)
        expect(Middleware.runSend(5, "t", nil)):toBe(10)
        c:disconnect()
    end)
    it("chains in order", function(): ()
        local c1 = Middleware.onSend(function(d: any): any
            return (d :: number) + 1
        end)
        local c2 = Middleware.onSend(function(d: any): any
            return (d :: number) * 10
        end)
        expect(Middleware.runSend(5, "t", nil)):toBe(60)
        c1:disconnect()
        c2:disconnect()
    end)
    it("nil return passes through", function(): ()
        local c = Middleware.onSend(function(_d: any): any
            return nil
        end)
        expect(Middleware.runSend(42, "t", nil)):toBe(42)
        c:disconnect()
    end)
    it("disconnect removes hook", function(): ()
        local c = Middleware.onSend(function(): any
            return 999
        end)
        c:disconnect()
        expect(Middleware.runSend(42, "t", nil)):toBe(42)
    end)
    it("hasSendHooks true when active", function(): ()
        local c = Middleware.onSend(function(d: any): any
            return d
        end)
        expect(Middleware.hasSendHooks()):toBe(true)
        c:disconnect()
    end)
end)

describe("Middleware: onReceive chain", function(): ()
    it("transforms received data", function(): ()
        local c = Middleware.onReceive(function(d: any): any
            return `got: {d}`
        end)
        expect(Middleware.runReceive("hello", "t", nil)):toBe("got: hello")
        c:disconnect()
    end)
    it("hasReceiveHooks true when active", function(): ()
        local c = Middleware.onReceive(function(d: any): any
            return d
        end)
        expect(Middleware.hasReceiveHooks()):toBe(true)
        c:disconnect()
    end)
    it("disconnect removes hook", function(): ()
        local c = Middleware.onReceive(function(): any
            return "nope"
        end)
        c:disconnect()
        expect(Middleware.runReceive("ok", "t", nil)):toBe("ok")
    end)
end)

describe("Middleware: onDrop", function(): ()
    it("fires handler", function(): ()
        local got: any = nil
        local c = Middleware.onDrop(function(_p: Player, reason: string, name: string): ()
            got = { reason = reason, name = name }
        end)
        Middleware.fireDrop({} :: any, "rate", "Hit", nil)
        expect(got.reason):toBe("rate")
        expect(got.name):toBe("Hit")
        c:disconnect()
    end)
    it("multiple handlers all fire", function(): ()
        local a, b = 0, 0
        local c1 = Middleware.onDrop(function(): ()
            a += 1
        end)
        local c2 = Middleware.onDrop(function(): ()
            b += 1
        end)
        Middleware.fireDrop({} :: any, "t", "n", nil)
        expect(a):toBe(1)
        expect(b):toBe(1)
        c1:disconnect()
        c2:disconnect()
    end)
    it("disconnect stops handler", function(): ()
        local count = 0
        local c = Middleware.onDrop(function(): ()
            count += 1
        end)
        Middleware.fireDrop({} :: any, "t", "n", nil)
        expect(count):toBe(1)
        c:disconnect()
        Middleware.fireDrop({} :: any, "t", "n", nil)
        expect(count):toBe(1)
    end)
end)

return nil
