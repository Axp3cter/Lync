--!strict
--!optimize 2
-- Lync.configure and Lync.start bounds checks (lifecycle smoke tests).

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("integration.Init", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("configure bounds", function(): ()
        it("rejects channelMaxSize below the lower bound", function(): ()
            expect(function(): ()
                Lync.configure({ channelMaxSize = 1024 })
            end):toThrow("channelMaxSize")
        end)
        it("rejects channelMaxSize above the upper bound", function(): ()
            expect(function(): ()
                Lync.configure({ channelMaxSize = 1024 * 1024 + 1 })
            end):toThrow("channelMaxSize")
        end)
        it("rejects validationDepth below 4", function(): ()
            expect(function(): ()
                Lync.configure({ validationDepth = 3 })
            end):toThrow("validationDepth")
        end)
        it("rejects validationDepth above 32", function(): ()
            expect(function(): ()
                Lync.configure({ validationDepth = 33 })
            end):toThrow("validationDepth")
        end)
        it("rejects poolSize below 2", function(): ()
            expect(function(): ()
                Lync.configure({ poolSize = 1 })
            end):toThrow("poolSize")
        end)
        it("rejects poolSize above 128", function(): ()
            expect(function(): ()
                Lync.configure({ poolSize = 200 })
            end):toThrow("poolSize")
        end)
        it("accepts valid config combinations", function(): ()
            expect(function(): ()
                Lync.configure({
                    channelMaxSize = 16384,
                    validationDepth = 8,
                    poolSize = 16,
                })
            end).never:toThrow()
        end)
    end)

    describe("flushRate bounds", function(): ()
        it("rejects below 1 hz", function(): ()
            expect(function(): ()
                Lync.flushRate(0)
            end):toThrow("hz")
        end)
        it("rejects above 60 hz", function(): ()
            expect(function(): ()
                Lync.flushRate(61)
            end):toThrow("hz")
        end)
        it("accepts 1, 30, 60", function(): ()
            expect(function(): ()
                Lync.flushRate(1)
                Lync.flushRate(30)
                Lync.flushRate(60)
            end).never:toThrow()
        end)
    end)

    describe("flush before start", function(): ()
        it("throws because Lync.start has not configured the transport", function(): ()
            expect(function(): ()
                Lync.flush()
            end):toThrow("Lync.start")
        end)
    end)

    describe("isStarted reflects state", function(): ()
        it("returns a boolean", function(): ()
            expect(Lync.isStarted()):toBeType("boolean")
        end)
    end)

    describe("targeting sentinels", function(): ()
        --[[
            Both sentinels share a single `_lyncKind` string field so target
            dispatch is one hash lookup at the same predicted slot.
        ]]
        it('Lync.all is a frozen sentinel branded "all"', function(): ()
            expect((Lync.all :: any)._lyncKind):toBe("all")
            expect(Lync.all):toBeFrozen()
        end)
        it('Lync.DROP is a frozen sentinel branded "drop"', function(): ()
            expect((Lync.DROP :: any)._lyncKind):toBe("drop")
            expect(Lync.DROP):toBeFrozen()
        end)
    end)

    describe("except builder", function(): ()
        it("requires Player or Group args", function(): ()
            expect(function(): ()
                Lync.except("not a player")
            end):toThrow("Player or Group")
        end)
        it("returns a frozen except sentinel", function(): ()
            local g = Lync.group("except_group")
            local exc = Lync.except(g)
            expect((exc :: any)._lyncKind):toBe("except")
            expect(exc):toBeFrozen()
        end)
    end)
end)

return nil
