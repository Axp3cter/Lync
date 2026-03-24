--!strict
--!optimize 2
local Pool = require(script.Parent.Parent.Parent.internal.Pool)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe("Pool: acquire", function(): ()
    it("returns fresh ChannelState", function(): ()
        local ch = Pool.acquire(); expect(ch.cursor):toBe(0); expect(ch.size):toBeGreaterThan(0); Pool.release(ch)
    end)
    it("cursor is reset on reuse", function(): ()
        local ch = Pool.acquire(); ch.cursor = 999; Pool.release(ch)
        local ch2 = Pool.acquire(); expect(ch2.cursor):toBe(0); Pool.release(ch2)
    end)
end)

describe("Pool: release and reuse", function(): ()
    it("released channel is reused", function(): ()
        local ch = Pool.acquire(); Pool.release(ch)
        local before = Pool.count()
        local ch2 = Pool.acquire()
        expect(Pool.count()):toBe(before - 1); Pool.release(ch2)
    end)
    it("count increases on release", function(): ()
        local ch = Pool.acquire(); local before = Pool.count()
        Pool.release(ch); expect(Pool.count()):toBe(before + 1)
    end)
end)

describe("Pool: max size", function(): ()
    it("respects limit", function(): ()
        Pool.setMaxSize(3)
        local channels: { any } = {}
        for i = 1, 5 do channels[i] = Pool.acquire() end
        for i = 1, 5 do Pool.release(channels[i]) end
        expect(Pool.count()):toBeLessThan(4)
        Pool.setMaxSize(16)
    end)
    it("setMaxSize trims excess", function(): ()
        for _ = 1, 10 do Pool.release(Pool.acquire()) end
        Pool.setMaxSize(2); expect(Pool.count()):toBeLessThan(3)
        Pool.setMaxSize(16)
    end)
end)

return nil
