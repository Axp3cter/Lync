--!strict
--!optimize 2
local Runner = require(script.Parent.Parent.Runner)
local Signal = require(script.Parent.Parent.Parent.api.Signal)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe("Signal fire+connect", function(): ()
    it("fires with argument", function(): ()
        local sig = Signal.create()
        local got: any
        sig:connect(function(v: any): ()
            got = v
        end)
        sig:fire(42)
        task.wait()
        expect(got):toBe(42)
    end)
    it("fires multiple listeners", function(): ()
        local sig = Signal.create()
        local a, b = 0, 0
        sig:connect(function(): ()
            a += 1
        end)
        sig:connect(function(): ()
            b += 1
        end)
        sig:fire()
        task.wait()
        expect(a):toBe(1)
        expect(b):toBe(1)
    end)
    it("passes multiple args", function(): ()
        local sig = Signal.create()
        local x, y: any
        sig:connect(function(a: any, b: any): ()
            x = a
            y = b
        end)
        sig:fire("hi", 99)
        task.wait(0.05)
        expect(x):toBe("hi")
        expect(y):toBe(99)
    end)
    it("no listeners safe", function(): ()
        Signal.create():fire(1)
    end)
end)

describe("Signal disconnect", function(): ()
    it("stops receiving", function(): ()
        local sig = Signal.create()
        local count = 0
        local conn = sig:connect(function(): ()
            count += 1
        end)
        sig:fire()
        task.wait()
        conn:disconnect()
        sig:fire()
        task.wait()
        expect(count):toBe(1)
    end)
    it("sets connected false", function(): ()
        local sig = Signal.create()
        local conn = sig:connect(function(): () end)
        expect(conn.connected):toBe(true)
        conn:disconnect()
        expect(conn.connected):toBe(false)
    end)
    it("double disconnect safe", function(): ()
        local sig = Signal.create()
        local conn = sig:connect(function(): () end)
        conn:disconnect()
        conn:disconnect()
    end)
end)

describe("Signal once", function(): ()
    it("fires once", function(): ()
        local sig = Signal.create()
        local count = 0
        sig:once(function(): ()
            count += 1
        end)
        sig:fire()
        task.wait()
        sig:fire()
        task.wait(0.1)
        expect(count):toBe(1)
    end)
    it("returns connection", function(): ()
        local sig = Signal.create()
        local conn = sig:once(function(): () end)
        expect(conn.connected):toBe(true)
        conn:disconnect()
        expect(conn.connected):toBe(false)
    end)
end)

describe("Signal disconnectAll", function(): ()
    it("clears all", function(): ()
        local sig = Signal.create()
        local count = 0
        sig:connect(function(): ()
            count += 1
        end)
        sig:connect(function(): ()
            count += 1
        end)
        sig:disconnectAll()
        sig:fire()
        task.wait()
        expect(count):toBe(0)
    end)
    it("safe on empty", function(): ()
        Signal.create():disconnectAll()
    end)
end)

describe("Signal wait", function(): ()
    it("yields then returns", function(): ()
        local sig = Signal.create()
        local got: any
        task.spawn(function(): ()
            got = sig:wait()
        end)
        task.wait()
        sig:fire("val")
        task.wait()
        expect(got):toBe("val")
    end)
end)

describe("Signal fireSync", function(): ()
    it("fires synchronously", function(): ()
        local sig = Signal.create()
        local got: any
        sig:connect(function(v: any): ()
            got = v
        end)
        sig:fireSync(77)
        expect(got):toBe(77)
    end)
end)

return nil
