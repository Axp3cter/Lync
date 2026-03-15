--!strict
--!optimize 2
local Runner   = require(script.Parent.Parent.Runner)
local Baseline = require(script.Parent.Parent.Parent.core.Baseline)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe("Baseline get/set", function(): ()
    it("nil for unset",     function(): () Baseline.setReadKey("__bl_a"); expect(Baseline.getCache(9999)):toBeNil() end)
    it("returns after set", function(): () Baseline.setReadKey("__bl_b"); Baseline.setCache(1, { hp = 100 }); expect((Baseline.getCache(1) :: any).hp):toBe(100) end)
    it("overwrites",        function(): () Baseline.setReadKey("__bl_c"); Baseline.setCache(1, "first"); Baseline.setCache(1, "second"); expect(Baseline.getCache(1)):toBe("second") end)
end)

describe("Baseline isolation", function(): ()
    it("different keys don't see each other", function(): ()
        Baseline.setReadKey("__bl_d"); Baseline.setCache(2, "from_d")
        Baseline.setReadKey("__bl_e"); expect(Baseline.getCache(2)):toBeNil()
        Baseline.setReadKey("__bl_d"); expect(Baseline.getCache(2)):toBe("from_d")
    end)
    it("false key (client sentinel) works", function(): ()
        Baseline.setReadKey(false)
        Baseline.setCache(99, "client_data")
        expect(Baseline.getCache(99)):toBe("client_data")
    end)
end)

describe("Baseline.clearSource", function(): ()
    it("removes all caches", function(): ()
        Baseline.setReadKey("__bl_f"); Baseline.setCache(10, "ten"); Baseline.setCache(20, "twenty")
        Baseline.clearSource("__bl_f")
        Baseline.setReadKey("__bl_f"); expect(Baseline.getCache(10)):toBeNil(); expect(Baseline.getCache(20)):toBeNil()
    end)
    it("doesn't affect other sources", function(): ()
        Baseline.setReadKey("__bl_g"); Baseline.setCache(30, "g")
        Baseline.setReadKey("__bl_h"); Baseline.setCache(30, "h")
        Baseline.clearSource("__bl_g")
        Baseline.setReadKey("__bl_h"); expect(Baseline.getCache(30)):toBe("h")
    end)
    it("clearing nonexistent key is safe", function(): ()
        expect(function(): () Baseline.clearSource("__bl_nonexistent") end).never:toThrow()
    end)
end)

return nil
