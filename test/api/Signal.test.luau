--!strict
--!optimize 2
local Runner = require(script.Parent.Parent.Runner)
local Signal = require(script.Parent.Parent.Parent.api.Signal)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe("Signal: connect and fire", function(): ()
    it("single listener receives value", function(): ()
        local sig = Signal.create()
        local r: any = nil
        sig:connect(function(v: any): ()
            r = v
        end)
        sig:fireSync(42)
        expect(r):toBe(42)
    end)
    it("multiple listeners in order", function(): ()
        local sig = Signal.create()
        local order: { number } = {}
        sig:connect(function(): ()
            table.insert(order, 1)
        end)
        sig:connect(function(): ()
            table.insert(order, 2)
        end)
        sig:connect(function(): ()
            table.insert(order, 3)
        end)
        sig:fireSync()
        expect(order[1]):toBe(1)
        expect(order[2]):toBe(2)
        expect(order[3]):toBe(3)
    end)
    it("passes multiple arguments", function(): ()
        local sig = Signal.create()
        local a, b, c: any
        sig:connect(function(x: any, y: any, z: any): ()
            a, b, c = x, y, z
        end)
        sig:fireSync("hello", 42, true)
        expect(a):toBe("hello")
        expect(b):toBe(42)
        expect(c):toBe(true)
    end)
    it("zero args fire", function(): ()
        local sig = Signal.create()
        local fired = false
        sig:connect(function(): ()
            fired = true
        end)
        sig:fireSync()
        expect(fired):toBe(true)
    end)
    it("no listeners = no error", function(): ()
        Signal.create():fireSync(1, 2, 3)
    end)
    it("nil argument preserved", function(): ()
        local sig = Signal.create()
        local got: any = "sentinel"
        sig:connect(function(v: any): ()
            got = v
        end)
        sig:fireSync(nil)
        expect(got):toBeNil()
    end)
end)

describe("Signal: disconnect", function(): ()
    it("stops receiving after disconnect", function(): ()
        local sig = Signal.create()
        local count = 0
        local conn = sig:connect(function(): ()
            count += 1
        end)
        sig:fireSync()
        expect(count):toBe(1)
        conn:disconnect()
        sig:fireSync()
        expect(count):toBe(1)
    end)
    it("double disconnect is safe", function(): ()
        local sig = Signal.create()
        local conn = sig:connect(function(): () end)
        conn:disconnect()
        conn:disconnect()
        expect(conn.connected):toBe(false)
    end)
    it("connected flag true before disconnect", function(): ()
        local conn = Signal.create():connect(function(): () end)
        expect(conn.connected):toBe(true)
    end)
    it("connected flag false after disconnect", function(): ()
        local conn = Signal.create():connect(function(): () end)
        conn:disconnect()
        expect(conn.connected):toBe(false)
    end)
    it("disconnect mid-fire skips disconnected entry", function(): ()
        local sig = Signal.create()
        local results: { string } = {}
        local connB: any
        sig:connect(function(): ()
            table.insert(results, "A")
            connB:disconnect()
        end)
        connB = sig:connect(function(): ()
            table.insert(results, "B")
        end)
        sig:fireSync()
        -- B was disconnected by A's callback, so B is correctly skipped
        expect(#results):toBe(1)
        expect(results[1]):toBe("A")
    end)
    it("disconnect first of three", function(): ()
        local sig = Signal.create()
        local results: { number } = {}
        local c1 = sig:connect(function(): ()
            table.insert(results, 1)
        end)
        sig:connect(function(): ()
            table.insert(results, 2)
        end)
        sig:connect(function(): ()
            table.insert(results, 3)
        end)
        c1:disconnect()
        sig:fireSync()
        expect(#results):toBe(2)
    end)
    it("disconnect last of three", function(): ()
        local sig = Signal.create()
        local results: { number } = {}
        sig:connect(function(): ()
            table.insert(results, 1)
        end)
        sig:connect(function(): ()
            table.insert(results, 2)
        end)
        local c3 = sig:connect(function(): ()
            table.insert(results, 3)
        end)
        c3:disconnect()
        sig:fireSync()
        expect(#results):toBe(2)
    end)
    it("disconnect middle of three", function(): ()
        local sig = Signal.create()
        local results: { number } = {}
        sig:connect(function(): ()
            table.insert(results, 1)
        end)
        local c2 = sig:connect(function(): ()
            table.insert(results, 2)
        end)
        sig:connect(function(): ()
            table.insert(results, 3)
        end)
        c2:disconnect()
        sig:fireSync()
        expect(#results):toBe(2)
    end)
end)

describe("Signal: once", function(): ()
    it("fires exactly once", function(): ()
        local sig = Signal.create()
        local count = 0
        sig:once(function(): ()
            count += 1
        end)
        sig:fireSync()
        sig:fireSync()
        sig:fireSync()
        expect(count):toBe(1)
    end)
    it("returns a connection", function(): ()
        local conn = Signal.create():once(function(): () end)
        expect(conn.connected):toBe(true)
    end)
    it("can be disconnected before firing", function(): ()
        local sig = Signal.create()
        local count = 0
        local conn = sig:once(function(): ()
            count += 1
        end)
        conn:disconnect()
        sig:fireSync()
        expect(count):toBe(0)
    end)
    it("connected = false after auto-disconnect", function(): ()
        local sig = Signal.create()
        local conn = sig:once(function(): () end)
        sig:fireSync()
        expect(conn.connected):toBe(false)
    end)
    it("passes arguments", function(): ()
        local sig = Signal.create()
        local got: any
        sig:once(function(v: any): ()
            got = v
        end)
        sig:fireSync("test")
        expect(got):toBe("test")
    end)
end)

describe("Signal: stress", function(): ()
    it("100 listeners all fire", function(): ()
        local sig = Signal.create()
        local total = 0
        for _ = 1, 100 do
            sig:connect(function(): ()
                total += 1
            end)
        end
        sig:fireSync()
        expect(total):toBe(100)
    end)
    it("disconnect 50 of 100", function(): ()
        local sig = Signal.create()
        local total = 0
        local conns: { any } = {}
        for i = 1, 100 do
            conns[i] = sig:connect(function(): ()
                total += 1
            end)
        end
        for i = 1, 50 do
            conns[i]:disconnect()
        end
        sig:fireSync()
        expect(total):toBe(50)
    end)
    it("disconnect all 100", function(): ()
        local sig = Signal.create()
        local total = 0
        local conns: { any } = {}
        for i = 1, 100 do
            conns[i] = sig:connect(function(): ()
                total += 1
            end)
        end
        for i = 1, 100 do
            conns[i]:disconnect()
        end
        sig:fireSync()
        expect(total):toBe(0)
    end)
    it("mixed connect + once", function(): ()
        local sig = Signal.create()
        local total = 0
        sig:connect(function(): ()
            total += 1
        end)
        sig:once(function(): ()
            total += 10
        end)
        sig:connect(function(): ()
            total += 1
        end)
        sig:fireSync()
        expect(total):toBe(12)
        total = 0
        sig:fireSync()
        expect(total):toBe(2)
    end)
end)

return nil
