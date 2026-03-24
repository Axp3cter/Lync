--!strict
--!optimize 2
local Signal = require(script.Parent.Parent.Parent.api.Signal)
local Scope = require(script.Parent.Parent.Parent.api.Scope)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

local function makeSource(): (any, any)
    local sig = Signal.create()
    local source = {
        on = function(_self: any, fn: any): any return sig:connect(fn) end,
        once = function(_self: any, fn: any): any return sig:once(fn) end,
    }
    return source, sig
end

describe("Scope: on tracks and returns connection", function(): ()
    it("listener fires", function(): ()
        local scope = Scope.create(); local source, sig = makeSource(); local count = 0
        scope:on(source, function(): () count += 1 end)
        sig:fireSync(); expect(count):toBe(1)
    end)
    it("returns the connection", function(): ()
        local scope = Scope.create(); local source, _ = makeSource()
        local conn = scope:on(source, function(): () end)
        expect(conn.connected):toBe(true)
    end)
    it("destroy disconnects", function(): ()
        local scope = Scope.create(); local source, sig = makeSource(); local count = 0
        scope:on(source, function(): () count += 1 end)
        sig:fireSync(); expect(count):toBe(1)
        scope:destroy(); sig:fireSync(); expect(count):toBe(1)
    end)
end)

describe("Scope: once", function(): ()
    it("fires once and tracks", function(): ()
        local scope = Scope.create(); local source, sig = makeSource(); local count = 0
        scope:once(source, function(): () count += 1 end)
        sig:fireSync(); sig:fireSync(); expect(count):toBe(1)
    end)
end)

describe("Scope: add external connections", function(): ()
    it("disconnects added connection on destroy", function(): ()
        local scope = Scope.create(); local sig = Signal.create(); local count = 0
        local conn = sig:connect(function(): () count += 1 end)
        scope:add(conn)
        sig:fireSync(); expect(count):toBe(1)
        scope:destroy(); expect(conn.connected):toBe(false)
        sig:fireSync(); expect(count):toBe(1)
    end)
end)

describe("Scope: multiple connections", function(): ()
    it("manages 50 connections", function(): ()
        local scope = Scope.create(); local sigs: { any } = {}; local total = 0
        for _ = 1, 50 do
            local source, sig = makeSource(); table.insert(sigs, sig)
            scope:on(source, function(): () total += 1 end)
        end
        for _, sig in sigs do sig:fireSync() end
        expect(total):toBe(50)
        scope:destroy(); total = 0
        for _, sig in sigs do sig:fireSync() end
        expect(total):toBe(0)
    end)
end)

describe("Scope: destroy idempotent", function(): ()
    it("safe to call multiple times", function(): ()
        local scope = Scope.create(); scope:destroy(); scope:destroy(); scope:destroy()
    end)
end)

return nil
