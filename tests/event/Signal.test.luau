--!strict
--!optimize 2
-- Signal.test.luau — Connect, disconnect, once, fire ordering, wait, disconnectAll.

local Runner = require(script.Parent.Parent.Runner)
local Signal = require(script.Parent.Parent.Parent.event.Signal)

local describe = Runner.describe
local it       = Runner.it
local expect   = Runner.expect

-- Tests ------------------------------------------------------------------

describe("Signal.fire + connect", function(): ()
    it("fires connected listener with arguments", function(): ()
        local signal   = Signal.create()
        local received = nil :: any

        signal:connect(function(value: any): ()
            received = value
        end)
        signal:fire(42)

        task.wait()
        expect(received):toBe(42)
    end)
    it("fires multiple listeners", function(): ()
        local signal = Signal.create()
        local count  = 0

        signal:connect(function(): () count += 1 end)
        signal:connect(function(): () count += 1 end)
        signal:connect(function(): () count += 1 end)
        signal:fire()

        task.wait()
        expect(count):toBe(3)
    end)
    it("passes multiple arguments", function(): ()
        local signal = Signal.create()
        local a, b, c = nil :: any, nil :: any, nil :: any

        signal:connect(function(x: any, y: any, z: any): ()
            a, b, c = x, y, z
        end)
        signal:fire(1, "two", true)

        task.wait()
        expect(a):toBe(1)
        expect(b):toBe("two")
        expect(c):toBe(true)
    end)
end)

describe("Signal.disconnect", function(): ()
    it("stops receiving after disconnect", function(): ()
        local signal = Signal.create()
        local count  = 0

        local conn = signal:connect(function(): ()
            count += 1
        end)
        signal:fire()
        task.wait()
        expect(count):toBe(1)

        conn:disconnect()
        signal:fire()
        task.wait()
        expect(count):toBe(1)
    end)
    it("sets connected to false", function(): ()
        local signal = Signal.create()
        local conn   = signal:connect(function(): () end)
        expect(conn.connected):toBe(true)

        conn:disconnect()
        expect(conn.connected):toBe(false)
    end)
    it("double disconnect is safe", function(): ()
        local signal = Signal.create()
        local conn   = signal:connect(function(): () end)
        conn:disconnect()
        expect(function(): ()
            conn:disconnect()
        end).never:toThrow()
    end)
end)

describe("Signal.once", function(): ()
    it("fires once then auto-disconnects", function(): ()
        local signal = Signal.create()
        local count  = 0

        signal:once(function(): ()
            count += 1
        end)
        signal:fire()
        task.wait()
        signal:fire()
        task.wait()

        expect(count):toBe(1)
    end)
end)

describe("Signal.disconnectAll", function(): ()
    it("disconnects all listeners", function(): ()
        local signal = Signal.create()
        local count  = 0

        local connA = signal:connect(function(): () count += 1 end)
        local connB = signal:connect(function(): () count += 1 end)
        signal:disconnectAll()

        signal:fire()
        task.wait()
        expect(count):toBe(0)
        expect(connA.connected):toBe(false)
        expect(connB.connected):toBe(false)
    end)
end)

describe("Signal.wait", function(): ()
    it("yields until fire and returns arguments", function(): ()
        local signal = Signal.create()
        local result = nil :: any

        task.defer(function(): ()
            result = signal:wait()
        end)

        task.wait()
        signal:fire(99)
        task.wait()

        expect(result):toBe(99)
    end)
end)

return nil
