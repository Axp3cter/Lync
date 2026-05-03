--!strict
--!optimize 2
-- internal.Pool: stack-based ChannelState pool with reset-on-acquire.

local Env = require(script:FindFirstAncestor("test").Env)

local Pool = Env.Internal.Pool
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("internal.Pool", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("acquire", function(): ()
        it("returns a fresh ChannelState", function(): ()
            local ch = Pool.acquire()
            expect(ch.cursor):toBe(0)
            expect(ch.size):toBeGreaterThan(0)
            Pool.release(ch)
        end)
        it("count starts at 0 after reset", function(): ()
            expect(Pool.count()):toBe(0)
        end)
        it("count = 0 after acquire (item left the pool)", function(): ()
            Pool.acquire()
            expect(Pool.count()):toBe(0)
        end)
    end)

    describe("release returns the channel to the pool", function(): ()
        it("count increments after release", function(): ()
            local ch = Pool.acquire()
            Pool.release(ch)
            expect(Pool.count()):toBe(1)
        end)
        it("acquire after release reuses the same ChannelState", function(): ()
            local first = Pool.acquire()
            Pool.release(first)
            local second = Pool.acquire()
            expect(second):toBe(first)
        end)
        it("reused channel is reset (cursor zeroed)", function(): ()
            local ch = Pool.acquire()
            ch.cursor = 999
            ch.refCount = 5
            Pool.release(ch)
            local reused = Pool.acquire()
            expect(reused.cursor):toBe(0)
            expect(reused.refCount):toBe(0)
        end)
    end)

    describe("setMaxSize bounds the pool", function(): ()
        it("excess releases drop the channel", function(): ()
            Pool.setMaxSize(2)
            local a = Pool.acquire()
            local b = Pool.acquire()
            local c = Pool.acquire()
            Pool.release(a)
            Pool.release(b)
            Pool.release(c)
            expect(Pool.count()):toBe(2)
        end)
        it("setMaxSize trims existing pool", function(): ()
            --[[
                Acquire then release in lockstep is a no-op cycle (pool
                oscillates 0->1->0->1). To actually fill the pool, acquire
                six distinct channels first, then release them all.
            ]]
            Pool.setMaxSize(10)
            local acquired: { any } = table.create(6)
            for i = 1, 6 do
                acquired[i] = Pool.acquire()
            end
            for i = 1, 6 do
                Pool.release(acquired[i])
            end
            expect(Pool.count()):toBe(6)
            Pool.setMaxSize(2)
            expect(Pool.count()):toBe(2)
        end)
        it("rejects negative max size", function(): ()
            expect(function(): ()
                Pool.setMaxSize(-1)
            end):toThrow("non-negative")
        end)
        it("setMaxSize(0) drops all pooled channels", function(): ()
            local a = Pool.acquire()
            Pool.release(a)
            expect(Pool.count()):toBe(1)
            Pool.setMaxSize(0)
            expect(Pool.count()):toBe(0)
        end)
        it("acquire after setMaxSize(0) still creates fresh channels", function(): ()
            Pool.setMaxSize(0)
            local ch = Pool.acquire()
            expect(ch).never:toBe(nil)
            expect(ch.cursor):toBe(0)
        end)
    end)

    describe("LIFO ordering", function(): ()
        it("most-recently-released channel is acquired first", function(): ()
            local a = Pool.acquire()
            local b = Pool.acquire()
            Pool.release(a)
            Pool.release(b)
            expect(Pool.acquire()):toBe(b)
            expect(Pool.acquire()):toBe(a)
        end)
    end)

    describe("acquired channel is reset on every reuse", function(): ()
        it("resets refs sidecar between uses", function(): ()
            local ch = Pool.acquire()
            ch.refs[1] = {} :: any
            ch.refCount = 1
            Pool.release(ch)
            local ch2 = Pool.acquire()
            expect(ch2.refCount):toBe(0)
        end)
        it("resets cursor between uses", function(): ()
            local ch = Pool.acquire()
            ch.cursor = 500
            Pool.release(ch)
            local ch2 = Pool.acquire()
            expect(ch2.cursor):toBe(0)
        end)
    end)

    describe("Sandbox.reset clears the pool", function(): ()
        it("count returns to 0 after resetAll", function(): ()
            local ch = Pool.acquire()
            Pool.release(ch)
            Sandbox.resetAll()
            expect(Pool.count()):toBe(0)
        end)
    end)

    describe("stress: 50 acquire/release cycles", function(): ()
        it("count stabilizes within configured max", function(): ()
            Pool.setMaxSize(8)
            for _ = 1, 50 do
                local ch = Pool.acquire()
                Pool.release(ch)
            end
            expect(Pool.count()):toBeLessThanOrEqual(8)
        end)
    end)
end)

return nil
