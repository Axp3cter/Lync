--!strict
--!optimize 2
-- Pool.test.luau — Acquire/release/warmup lifecycle tests.

local Runner = require(script.Parent.Parent.Runner)
local Pool   = require(script.Parent.Parent.Parent.core.Pool)

local describe = Runner.describe
local it       = Runner.it
local expect   = Runner.expect

-- Tests ------------------------------------------------------------------

describe("Pool.acquire", function(): ()
    it("returns a fresh channel with cursor at 0", function(): ()
        local ch = Pool.acquire()
        expect(ch.cursor):toBe(0)
        expect(ch.size):toBe(256)
        Pool.release(ch)
    end)
end)

describe("Pool.release + reacquire", function(): ()
    it("reuses released channels", function(): ()
        local ch = Pool.acquire()
        buffer.writeu8(ch.buff, 0, 0xFF)
        ch.cursor = 10
        Pool.release(ch)

        local reused = Pool.acquire()
        expect(reused.cursor):toBe(0)
        expect(#reused.refs):toBe(0)
    end)
end)

describe("Pool.warmup", function(): ()
    it("pre-fills the pool with ready channels", function(): ()
        Pool.warmup(4)
        local channels = {}
        for i = 1, 4 do
            channels[i] = Pool.acquire()
            expect(channels[i].cursor):toBe(0)
        end
        for _, ch in channels do
            Pool.release(ch)
        end
    end)
end)

return nil
