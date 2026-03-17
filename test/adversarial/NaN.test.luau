--!strict
--!optimize 2
local Gate = require (script.Parent.Parent.Parent.transport.Gate)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect, fakePlayer =
    Runner.describe, Runner.it, Runner.expect, Runner.fakePlayer

local nan = 0 / 0

local function reg (): any
    return {
        id = 80000,
        name = "__nan",
        baseName = "__nan",
        codec = { write = function () end, read = function () end },
        isUnreliable = false,
        kind = 0,
        partner = nil,
        signal = nil,
        rateLimit = nil,
        validate = nil,
        needsGate = false,
        maxPayloadBytes = nil,
    }
end

describe ("NaN rejection", function (): ()
    local p = fakePlayer ("NaN", 4000)
    Gate.onPlayerAdded (p)
    local r = reg ()

    it ("rejects NaN", function (): ()
        expect (Gate.check (nan, r, p)):toBe (false)
    end)
    it ("inf", function (): ()
        expect (Gate.check (math.huge, r, p)):toBe (false)
    end)
    it ("-inf", function (): ()
        expect (Gate.check (-math.huge, r, p)):toBe (false)
    end)
    it ("rejects NaN Vector2", function (): ()
        expect (Gate.check (Vector2.new (nan, 0), r, p)):toBe (false)
    end)
    it ("rejects NaN Vector3", function (): ()
        expect (Gate.check (Vector3.new (0, nan, 0), r, p)):toBe (false)
    end)
    it ("rejects NaN Color3", function (): ()
        expect (Gate.check (Color3.new (nan, 0, 0), r, p)):toBe (false)
    end)
    it ("rejects NaN UDim", function (): ()
        expect (Gate.check (UDim.new (nan, 0), r, p)):toBe (false)
    end)
    it ("rejects NaN UDim2", function (): ()
        expect (Gate.check (UDim2.new (UDim.new (nan, 0), UDim.new (0, 0)), r, p)):toBe (false)
    end)
    it ("rejects NaN NumberRange", function (): ()
        expect (Gate.check (NumberRange.new (nan, 1), r, p)):toBe (false)
    end)
    it ("rejects NaN Rect", function (): ()
        expect (Gate.check (Rect.new (nan, 0, 1, 1), r, p)):toBe (false)
    end)
    it ("rejects NaN Ray origin", function (): ()
        expect (Gate.check (Ray.new (Vector3.new (nan, 0, 0), Vector3.yAxis), r, p)):toBe (false)
    end)
    it ("rejects NaN Ray direction", function (): ()
        expect (Gate.check (Ray.new (Vector3.zero, Vector3.new (0, nan, 0)), r, p)):toBe (false)
    end)
    it ("rejects NaN Region3", function (): ()
        expect (Gate.check (Region3.new (Vector3.new (nan, 0, 0), Vector3.one), r, p)):toBe (false)
    end)
    it ("rejects NaN in table", function (): ()
        expect (Gate.check ({ x = nan }, r, p)):toBe (false)
    end)
    it ("rejects deep nested NaN", function (): ()
        expect (Gate.check ({ a = { b = { c = nan } } }, r, p)):toBe (false)
    end)
    it ("accepts number", function (): ()
        expect (Gate.check (42, r, p)):toBe (true)
    end)
    it ("accepts string", function (): ()
        expect (Gate.check ("hi", r, p)):toBe (true)
    end)
    it ("accepts table", function (): ()
        expect (Gate.check ({ x = 1 }, r, p)):toBe (true)
    end)

    Gate.onPlayerRemoved (p)
end)

return nil
