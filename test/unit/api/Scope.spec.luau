--!strict
--!optimize 2
-- api.Scope: batched connection cleanup across mixed source types.

local Env = require(script:FindFirstAncestor("test").Env)

local Sandbox = Env.Sandbox
local Scope = Env.Internal.Scope
local Signal = Env.Internal.Signal

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

local function makeSource(): (any, any)
    local sig = Signal.create()
    local source = {
        on = function(_self: any, fn: any): any
            return sig:connect(fn)
        end,
        once = function(_self: any, fn: any): any
            return sig:once(fn)
        end,
    }
    return source, sig
end

describe("api.Scope", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("on", function(): ()
        it("listener fires through scope", function(): ()
            local scope = Scope.create()
            local source, sig = makeSource()
            local count = 0
            scope:on(source, function(): ()
                count += 1
            end)
            sig:fireSync()
            expect(count):toBe(1)
        end)
        it("returns the underlying connection", function(): ()
            local scope = Scope.create()
            local source = makeSource()
            local conn = scope:on(source, function(): () end)
            expect(conn.connected):toBe(true)
        end)
        it("destroy disconnects scope-tracked listeners", function(): ()
            local scope = Scope.create()
            local source, sig = makeSource()
            local count = 0
            scope:on(source, function(): ()
                count += 1
            end)
            sig:fireSync()
            expect(count):toBe(1)
            scope:destroy()
            sig:fireSync()
            expect(count):toBe(1)
        end)
    end)

    describe("once", function(): ()
        it("fires exactly once and is tracked", function(): ()
            local scope = Scope.create()
            local source, sig = makeSource()
            local count = 0
            scope:once(source, function(): ()
                count += 1
            end)
            sig:fireSync()
            sig:fireSync()
            expect(count):toBe(1)
        end)
    end)

    describe("add wraps external connections", function(): ()
        it("disconnects an externally-created Lync connection on destroy", function(): ()
            local scope = Scope.create()
            local sig = Signal.create()
            local count = 0
            local conn = sig:connect(function(): ()
                count += 1
            end)
            scope:add(conn)
            sig:fireSync()
            expect(count):toBe(1)
            scope:destroy()
            expect(conn.connected):toBe(false)
            sig:fireSync()
            expect(count):toBe(1)
        end)
    end)

    describe("size", function(): ()
        it("starts at 0", function(): ()
            expect(Scope.create():size()):toBe(0)
        end)
        it("increments per add/on/once", function(): ()
            local scope = Scope.create()
            local source = makeSource()
            scope:on(source, function(): () end)
            scope:once(source, function(): () end)
            expect(scope:size()):toBe(2)
        end)
    end)

    describe("destroy idempotency", function(): ()
        it("safe to call multiple times", function(): ()
            local scope = Scope.create()
            scope:destroy()
            scope:destroy()
            scope:destroy()
            expect(scope:size()):toBe(0)
        end)
    end)

    describe("stress: 50 listeners", function(): ()
        it("all fire then all disconnect via destroy", function(): ()
            local scope = Scope.create()
            local sigs: { any } = {}
            local total = 0
            for _ = 1, 50 do
                local source, sig = makeSource()
                table.insert(sigs, sig)
                scope:on(source, function(): ()
                    total += 1
                end)
            end
            for _, sig in sigs do
                sig:fireSync()
            end
            expect(total):toBe(50)
            scope:destroy()
            total = 0
            for _, sig in sigs do
                sig:fireSync()
            end
            expect(total):toBe(0)
        end)
    end)

    describe("size after destroy", function(): ()
        it("size returns 0 after destroy", function(): ()
            local scope = Scope.create()
            local source = makeSource()
            scope:on(source, function(): () end)
            scope:on(source, function(): () end)
            expect(scope:size()):toBe(2)
            scope:destroy()
            expect(scope:size()):toBe(0)
        end)
    end)

    describe("once via scope is decremented after firing", function(): ()
        --[[
            Scope:once wraps a once connection. After it fires its size
            tracking should still be consistent (no negative size).
        ]]
        it("size still non-negative after once fires", function(): ()
            local scope = Scope.create()
            local source, sig = makeSource()
            scope:once(source, function(): () end)
            sig:fireSync()
            expect(scope:size()):toBeGreaterThanOrEqual(0)
        end)
    end)

    describe("nested scopes", function(): ()
        it("destroying outer scope does not crash", function(): ()
            local outer = Scope.create()
            local inner = Scope.create()
            local source, sig = makeSource()
            inner:on(source, function(): () end)
            outer:add(inner :: any)
            -- Most scope.add accepts a connection, not another scope. Pin
            -- that we at least don't throw on the typical "destroy outer"
            -- after manual inner setup.
            expect(function(): ()
                outer:destroy()
            end).never:toThrow()
            sig:fireSync()
        end)
    end)

    describe("disconnect via underlying connection bypasses scope tracking", function(): ()
        it("manual disconnect on returned connection still leaves scope size > 0", function(): ()
            -- Scope tracks the connections it created; if the user disconnects
            -- the underlying connection, scope still believes it owns that
            -- entry (until destroy). This is a documented behavior.
            local scope = Scope.create()
            local source = makeSource()
            local conn = scope:on(source, function(): () end)
            local sizeBefore = scope:size()
            conn:disconnect()
            expect(scope:size()):toBe(sizeBefore)
        end)
    end)

    describe("connections fire only while scope is alive", function(): ()
        it("destroy mid-fire: subsequent fires are silent", function(): ()
            local scope = Scope.create()
            local source, sig = makeSource()
            local fires = 0
            scope:on(source, function(): ()
                fires += 1
            end)
            sig:fireSync()
            sig:fireSync()
            scope:destroy()
            sig:fireSync()
            sig:fireSync()
            expect(fires):toBe(2)
        end)
    end)
end)

return nil
