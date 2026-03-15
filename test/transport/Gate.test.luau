--!strict
--!optimize 2
local Gate = require (script.Parent.Parent.Parent.transport.Gate)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect, fakePlayer =
    Runner.describe, Runner.it, Runner.expect, Runner.fakePlayer

local function reg (ov: any?): any
    local b = {
        id = 9999,
        name = "__tg",
        baseName = "__tg",
        codec = { write = function () end, read = function () end },
        isUnreliable = false,
        kind = 0,
        partner = nil,
        signal = nil,
        rateLimit = nil,
        validate = nil,
    }
    if ov then
        for k, v in ov :: { [string]: any } do
            b[k] = v
        end
    end
    return b
end

describe ("Gate NaN/inf", function (): ()
    it ("rejects NaN", function (): ()
        local p = fakePlayer ()
        Gate.onPlayerAdded (p)
        expect (Gate.check (0 / 0, reg (), p)):toBe (false)
        Gate.onPlayerRemoved (p)
    end)
    it ("rejects inf", function (): ()
        local p = fakePlayer ()
        Gate.onPlayerAdded (p)
        expect (Gate.check (math.huge, reg (), p)):toBe (false)
        Gate.onPlayerRemoved (p)
    end)
    it ("rejects -inf", function (): ()
        local p = fakePlayer ()
        Gate.onPlayerAdded (p)
        expect (Gate.check (-math.huge, reg (), p)):toBe (false)
        Gate.onPlayerRemoved (p)
    end)
    it ("accepts number", function (): ()
        local p = fakePlayer ()
        Gate.onPlayerAdded (p)
        expect (Gate.check (42, reg (), p)):toBe (true)
        Gate.onPlayerRemoved (p)
    end)
    it ("accepts string", function (): ()
        local p = fakePlayer ()
        Gate.onPlayerAdded (p)
        expect (Gate.check ("hello", reg (), p)):toBe (true)
        Gate.onPlayerRemoved (p)
    end)
    it ("accepts bool", function (): ()
        local p = fakePlayer ()
        Gate.onPlayerAdded (p)
        expect (Gate.check (true, reg (), p)):toBe (true)
        Gate.onPlayerRemoved (p)
    end)
    it ("accepts nil", function (): ()
        local p = fakePlayer ()
        Gate.onPlayerAdded (p)
        expect (Gate.check (nil, reg (), p)):toBe (true)
        Gate.onPlayerRemoved (p)
    end)
end)

describe ("Gate table NaN", function (): ()
    it ("in value", function (): ()
        local p = fakePlayer ()
        Gate.onPlayerAdded (p)
        expect (Gate.check ({ hp = 0 / 0 }, reg (), p)):toBe (false)
        Gate.onPlayerRemoved (p)
    end)
    it ("deeply nested", function (): ()
        local p = fakePlayer ()
        Gate.onPlayerAdded (p)
        expect (Gate.check ({ a = { b = { c = 0 / 0 } } }, reg (), p)):toBe (false)
        Gate.onPlayerRemoved (p)
    end)
    it ("exceeds depth", function (): ()
        local p = fakePlayer ()
        Gate.onPlayerAdded (p)
        local deep: any = { val = 1 }
        for _ = 1, 10 do
            deep = { inner = deep }
        end
        expect (Gate.check (deep, reg (), p)):toBe (false)
        Gate.onPlayerRemoved (p)
    end)
    it ("accepts clean table", function (): ()
        local p = fakePlayer ()
        Gate.onPlayerAdded (p)
        expect (Gate.check ({ a = 1, b = "hi", c = { d = true } }, reg (), p)):toBe (true)
        Gate.onPlayerRemoved (p)
    end)
    it ("accepts empty table", function (): ()
        local p = fakePlayer ()
        Gate.onPlayerAdded (p)
        expect (Gate.check ({}, reg (), p)):toBe (true)
        Gate.onPlayerRemoved (p)
    end)
end)

describe ("Gate Vector2 NaN", function (): ()
    it ("rejects NaN X", function (): ()
        local p = fakePlayer ()
        Gate.onPlayerAdded (p)
        expect (Gate.check (Vector2.new (0 / 0, 1), reg (), p)):toBe (false)
        Gate.onPlayerRemoved (p)
    end)
    it ("rejects NaN Y", function (): ()
        local p = fakePlayer ()
        Gate.onPlayerAdded (p)
        expect (Gate.check (Vector2.new (1, 0 / 0), reg (), p)):toBe (false)
        Gate.onPlayerRemoved (p)
    end)
    it ("accepts clean", function (): ()
        local p = fakePlayer ()
        Gate.onPlayerAdded (p)
        expect (Gate.check (Vector2.new (1, 2), reg (), p)):toBe (true)
        Gate.onPlayerRemoved (p)
    end)
end)

describe ("Gate Vector3 NaN", function (): ()
    it ("rejects NaN", function (): ()
        local p = fakePlayer ()
        Gate.onPlayerAdded (p)
        expect (Gate.check (Vector3.new (1, 0 / 0, 3), reg (), p)):toBe (false)
        Gate.onPlayerRemoved (p)
    end)
    it ("accepts clean", function (): ()
        local p = fakePlayer ()
        Gate.onPlayerAdded (p)
        expect (Gate.check (Vector3.new (1, 2, 3), reg (), p)):toBe (true)
        Gate.onPlayerRemoved (p)
    end)
end)

describe ("Gate Color3 NaN", function (): ()
    it ("rejects NaN R", function (): ()
        local p = fakePlayer ()
        Gate.onPlayerAdded (p)
        expect (Gate.check (Color3.new (0 / 0, 0, 0), reg (), p)):toBe (false)
        Gate.onPlayerRemoved (p)
    end)
    it ("rejects NaN G", function (): ()
        local p = fakePlayer ()
        Gate.onPlayerAdded (p)
        expect (Gate.check (Color3.new (0, 0 / 0, 0), reg (), p)):toBe (false)
        Gate.onPlayerRemoved (p)
    end)
    it ("rejects NaN B", function (): ()
        local p = fakePlayer ()
        Gate.onPlayerAdded (p)
        expect (Gate.check (Color3.new (0, 0, 0 / 0), reg (), p)):toBe (false)
        Gate.onPlayerRemoved (p)
    end)
    it ("accepts clean", function (): ()
        local p = fakePlayer ()
        Gate.onPlayerAdded (p)
        expect (Gate.check (Color3.new (1, 0.5, 0), reg (), p)):toBe (true)
        Gate.onPlayerRemoved (p)
    end)
end)

describe ("Gate CFrame", function (): ()
    it ("accepts clean", function (): ()
        local p = fakePlayer ()
        Gate.onPlayerAdded (p)
        expect (Gate.check (CFrame.new (1, 2, 3), reg (), p)):toBe (true)
        Gate.onPlayerRemoved (p)
    end)
    it ("accepts rotated", function (): ()
        local p = fakePlayer ()
        Gate.onPlayerAdded (p)
        expect (Gate.check (CFrame.Angles (1, 2, 3), reg (), p)):toBe (true)
        Gate.onPlayerRemoved (p)
    end)
end)

describe ("Gate rate limiting", function (): ()
    it ("allows first", function (): ()
        local p = fakePlayer ("RA", 100)
        Gate.onPlayerAdded (p)
        expect (Gate.check (1, reg ({ rateLimit = { maxPerSecond = 2 } }), p)):toBe (true)
        Gate.onPlayerRemoved (p)
    end)
    it ("rejects after burst", function (): ()
        local p = fakePlayer ("RB", 101)
        Gate.onPlayerAdded (p)
        local r = reg ({ id = 10001, rateLimit = { maxPerSecond = 1, burstAllowance = 2 } })
        Gate.check (1, r, p)
        Gate.check (1, r, p)
        expect (Gate.check (1, r, p)):toBe (false)
        Gate.onPlayerRemoved (p)
    end)
    it ("passes without rateLimit", function (): ()
        local p = fakePlayer ("RC", 102)
        Gate.onPlayerAdded (p)
        for _ = 1, 100 do
            expect (Gate.check (1, reg (), p)):toBe (true)
        end
        Gate.onPlayerRemoved (p)
    end)
    it ("rate runs before NaN", function (): ()
        local p = fakePlayer ("RD", 103)
        Gate.onPlayerAdded (p)
        local r = reg ({ id = 10002, rateLimit = { maxPerSecond = 1, burstAllowance = 1 } })
        Gate.check (1, r, p)
        local dropped: any
        Gate.onDrop (function (_, reason: string): ()
            dropped = reason
        end)
        Gate.check (0 / 0, r, p)
        expect (dropped):toBe ("rate")
        Gate.onPlayerRemoved (p)
        Gate.onDrop (nil :: any)
    end)
end)

describe ("Gate validate", function (): ()
    it ("rejects false", function (): ()
        local p = fakePlayer ("VA", 200)
        Gate.onPlayerAdded (p)
        expect (Gate.check (
            1,
            reg ({
                validate = function ()
                    return false, "bad"
                end,
            }),
            p
        )):toBe (false)
        Gate.onPlayerRemoved (p)
    end)
    it ("accepts true", function (): ()
        local p = fakePlayer ("VB", 201)
        Gate.onPlayerAdded (p)
        expect (Gate.check (
            42,
            reg ({
                validate = function ()
                    return true
                end,
            }),
            p
        )):toBe (true)
        Gate.onPlayerRemoved (p)
    end)
end)

describe ("Gate onDrop", function (): ()
    it ("fires on NaN", function (): ()
        local dropped: any
        Gate.onDrop (function (_, reason: string, name: string): ()
            dropped = { reason = reason, name = name }
        end)
        local p = fakePlayer ("DA", 300)
        Gate.onPlayerAdded (p)
        Gate.check (0 / 0, reg ({ name = "__drop" }), p)
        expect (dropped).never:toBeNil ()
        expect (dropped.reason):toBe ("nan")
        expect (dropped.name):toBe ("__drop")
        Gate.onPlayerRemoved (p)
        Gate.onDrop (nil :: any)
    end)
    it ("fires on validate fail", function (): ()
        local reason: string?
        Gate.onDrop (function (_, r: string): ()
            reason = r
        end)
        local p = fakePlayer ("DB", 301)
        Gate.onPlayerAdded (p)
        Gate.check (
            1,
            reg ({
                validate = function ()
                    return false, "custom_reason"
                end,
            }),
            p
        )
        expect (reason):toBe ("custom_reason")
        Gate.onPlayerRemoved (p)
        Gate.onDrop (nil :: any)
    end)
    it ("fires on rate", function (): ()
        local reason: string?
        Gate.onDrop (function (_, r: string): ()
            reason = r
        end)
        local p = fakePlayer ("DC", 302)
        Gate.onPlayerAdded (p)
        local r = reg ({ id = 10003, rateLimit = { maxPerSecond = 1, burstAllowance = 1 } })
        Gate.check (1, r, p)
        Gate.check (1, r, p)
        expect (reason):toBe ("rate")
        Gate.onPlayerRemoved (p)
        Gate.onDrop (nil :: any)
    end)
end)

return nil
