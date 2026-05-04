--!strict
--!optimize 2
-- api.Signal: O(1) disconnect, snapshot semantics, fire vs fireSync.

local Env = require(script:FindFirstAncestor("test").Env)

local Sandbox = Env.Sandbox
local Signal = Env.Internal.Signal

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("api.Signal", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("create + fireSync delivers args", function(): ()
        it("single listener receives value", function(): ()
            local sig = Signal.create()
            local got: any = nil
            sig:connect(function(v: any): ()
                got = v
            end)
            sig:fireSync(42)
            expect(got):toBe(42)
        end)
        it("multiple args pass through", function(): ()
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
        it("zero-arg fire", function(): ()
            local sig = Signal.create()
            local fired = false
            sig:connect(function(): ()
                fired = true
            end)
            sig:fireSync()
            expect(fired):toBe(true)
        end)
        it("fire with no listeners is a no-op", function(): ()
            local sig = Signal.create()
            sig:fireSync(1, 2, 3)
            expect(sig:hasListeners()):toBe(false)
        end)
        it("nil arg preserved", function(): ()
            local sig = Signal.create()
            local got: any = "sentinel"
            sig:connect(function(v: any): ()
                got = v
            end)
            sig:fireSync(nil)
            expect(got):toBeNil()
        end)
        it("count() reports 0 after disconnect of only listener", function(): ()
            local sig = Signal.create()
            local c = sig:connect(function(): () end)
            expect(sig:count()):toBe(1)
            c:disconnect()
            expect(sig:count()):toBe(0)
        end)
    end)

    describe("multiple listeners", function(): ()
        it("fire dispatches in registration order", function(): ()
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
    end)

    describe("disconnect", function(): ()
        it("stops receiving", function(): ()
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
        it("idempotent (double disconnect is safe)", function(): ()
            local sig = Signal.create()
            local conn = sig:connect(function(): () end)
            conn:disconnect()
            conn:disconnect()
            expect(conn.connected):toBe(false)
        end)
        it("connected = true before, false after", function(): ()
            local sig = Signal.create()
            local conn = sig:connect(function(): () end)
            expect(conn.connected):toBe(true)
            conn:disconnect()
            expect(conn.connected):toBe(false)
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

    describe("snapshot semantics during fire", function(): ()
        it("disconnect mid-fire skips that listener", function(): ()
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
            expect(#results):toBe(1)
            expect(results[1]):toBe("A")
        end)
        it("connect mid-fire does NOT invoke new listener in current fire", function(): ()
            --[[
                The snapshot is taken at fire start. Listeners added during
                dispatch must not run until the next fire.
            ]]
            local sig = Signal.create()
            local order: { string } = {}
            sig:connect(function(): ()
                table.insert(order, "first")
                sig:connect(function(): ()
                    table.insert(order, "added")
                end)
            end)
            sig:fireSync()
            expect(#order):toBe(1)
            expect(order[1]):toBe("first")
            sig:fireSync()
            expect(#order):toBe(3)
            expect(order[2]):toBe("first")
            expect(order[3]):toBe("added")
        end)
    end)

    describe("once", function(): ()
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

    describe("async fire (uses thread reuse path)", function(): ()
        it("non-yielding listeners run synchronously from caller's view", function(): ()
            local sig = Signal.create()
            local count = 0
            sig:connect(function(): ()
                count += 1
            end)
            sig:fire()
            expect(count):toBe(1)
        end)
        it("100 fires of 5 listeners all execute", function(): ()
            local sig = Signal.create()
            local total = 0
            for _ = 1, 5 do
                sig:connect(function(): ()
                    total += 1
                end)
            end
            for _ = 1, 100 do
                sig:fire()
            end
            expect(total):toBe(500)
        end)
    end)

    describe("stress", function(): ()
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
        it("disconnect 50 of 100 leaves 50", function(): ()
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
        it("hasListeners reflects state", function(): ()
            local sig = Signal.create()
            expect(sig:hasListeners()):toBe(false)
            local conn = sig:connect(function(): () end)
            expect(sig:hasListeners()):toBe(true)
            conn:disconnect()
            expect(sig:hasListeners()):toBe(false)
        end)
    end)

    describe("wait", function(): ()
        it("yields until next fire", function(): ()
            local sig = Signal.create()
            task.delay(0, function(): ()
                sig:fireSync("delivered")
            end)
            local v = sig:wait()
            expect(v):toBe("delivered")
        end)
    end)

    describe("async dispatch survives a handler error", function(): ()
        -- The recycled-thread fast path used to be permanently consumed by a
        -- single handler error: every subsequent fire then paid coroutine.create.
        it("subsequent fires still dispatch after a thrown handler", function(): ()
            local sig = Signal.create()
            sig:connect(function(): ()
                error("handler boom", 0)
            end)
            local laterFires = 0
            sig:connect(function(): ()
                laterFires += 1
            end)

            -- async fire (not fireSync) so spawnCallback runs through `passer`.
            sig:fire(1)
            sig:fire(2)
            sig:fire(3)
            -- yield once so the recycled thread completes its work.
            task.wait(0)
            -- Each fire ran the second handler at least once.
            expect(laterFires):toBeGreaterThanOrEqual(3)
        end)
    end)
end)

return nil
