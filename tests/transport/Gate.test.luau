--!strict
--!optimize 2
-- Gate.test.luau — NaN/inf rejection, rate limiting, custom validation.

local Gate = require (script.Parent.Parent.Parent.transport.Gate)
local Runner = require (script.Parent.Parent.Runner)

local describe = Runner.describe
local it = Runner.it
local expect = Runner.expect
local fakePlayer = Runner.fakePlayer

-- Helpers ----------------------------------------------------------------

local function makeReg (overrides: any?): any
    local base = {
        id = 9999,
        name = "__test_gate",
        baseName = "__test_gate",
        codec = { write = function () end, read = function () end },
        reliability = "reliable",
        kind = "packet",
        partner = nil,
        signal = nil,
        rateLimit = nil,
        validate = nil,
    }
    if overrides then
        for k, v in overrides :: { [string]: any } do
            base[k] = v
        end
    end
    return base
end

-- Tests ------------------------------------------------------------------

describe ("Gate NaN/inf rejection", function (): ()
    it ("rejects NaN number", function (): ()
        local player = fakePlayer ()
        Gate.onPlayerAdded (player)
        expect (Gate.check (0 / 0, makeReg (), player)):toBe (false)
        Gate.onPlayerRemoved (player)
    end)
    it ("rejects inf number", function (): ()
        local player = fakePlayer ()
        Gate.onPlayerAdded (player)
        expect (Gate.check (math.huge, makeReg (), player)):toBe (false)
        Gate.onPlayerRemoved (player)
    end)
    it ("rejects -inf number", function (): ()
        local player = fakePlayer ()
        Gate.onPlayerAdded (player)
        expect (Gate.check (-math.huge, makeReg (), player)):toBe (false)
        Gate.onPlayerRemoved (player)
    end)
    it ("accepts clean number", function (): ()
        local player = fakePlayer ()
        Gate.onPlayerAdded (player)
        expect (Gate.check (42, makeReg (), player)):toBe (true)
        Gate.onPlayerRemoved (player)
    end)
    it ("accepts clean string", function (): ()
        local player = fakePlayer ()
        Gate.onPlayerAdded (player)
        expect (Gate.check ("hello", makeReg (), player)):toBe (true)
        Gate.onPlayerRemoved (player)
    end)
    it ("rejects table containing NaN value", function (): ()
        local player = fakePlayer ()
        Gate.onPlayerAdded (player)
        expect (Gate.check ({ hp = 0 / 0 }, makeReg (), player)):toBe (false)
        Gate.onPlayerRemoved (player)
    end)
    it ("rejects Vector3 with NaN component", function (): ()
        local player = fakePlayer ()
        Gate.onPlayerAdded (player)
        expect (Gate.check (Vector3.new (1, 0 / 0, 3), makeReg (), player)):toBe (false)
        Gate.onPlayerRemoved (player)
    end)
    it ("accepts clean Vector3", function (): ()
        local player = fakePlayer ()
        Gate.onPlayerAdded (player)
        expect (Gate.check (Vector3.new (1, 2, 3), makeReg (), player)):toBe (true)
        Gate.onPlayerRemoved (player)
    end)
end)

describe ("Gate rate limiting", function (): ()
    it ("allows first request within limit", function (): ()
        local player = fakePlayer ("RateA", 100)
        Gate.onPlayerAdded (player)
        expect (Gate.check (1, makeReg ({ rateLimit = { maxPerSecond = 2 } }), player)):toBe (true)
        Gate.onPlayerRemoved (player)
    end)
    it ("rejects after exhausting burst", function (): ()
        local player = fakePlayer ("RateB", 101)
        Gate.onPlayerAdded (player)

        local reg = makeReg ({
            id = 10001,
            rateLimit = { maxPerSecond = 1, burstAllowance = 2 },
        })

        Gate.check (1, reg, player)
        Gate.check (1, reg, player)
        expect (Gate.check (1, reg, player)):toBe (false)

        Gate.onPlayerRemoved (player)
    end)
    it ("passes when no rateLimit is configured", function (): ()
        local player = fakePlayer ("RateC", 102)
        Gate.onPlayerAdded (player)

        for _ = 1, 100 do
            expect (Gate.check (1, makeReg (), player)):toBe (true)
        end

        Gate.onPlayerRemoved (player)
    end)
end)

describe ("Gate custom validate", function (): ()
    it ("rejects when validate returns false", function (): ()
        local player = fakePlayer ("ValA", 200)
        Gate.onPlayerAdded (player)

        local reg = makeReg ({
            validate = function (_data: any, _player: Player): (boolean, string?)
                return false, "too_low"
            end,
        })
        expect (Gate.check (1, reg, player)):toBe (false)

        Gate.onPlayerRemoved (player)
    end)
    it ("accepts when validate returns true", function (): ()
        local player = fakePlayer ("ValB", 201)
        Gate.onPlayerAdded (player)

        local reg = makeReg ({
            validate = function (_data: any, _player: Player): (boolean, string?)
                return true, nil
            end,
        })
        expect (Gate.check (42, reg, player)):toBe (true)

        Gate.onPlayerRemoved (player)
    end)
end)

describe ("Gate.onDrop callback", function (): ()
    it ("fires callback with reason on rejection", function (): ()
        local dropped = nil :: any
        Gate.onDrop (function (player: Player, reason: string, packetName: string, _data: any?): ()
            dropped = { player = player, reason = reason, name = packetName }
        end)

        local player = fakePlayer ("DropA", 300)
        Gate.onPlayerAdded (player)
        Gate.check (0 / 0, makeReg ({ name = "__drop_test" }), player)

        expect (dropped).never:toBeNil ()
        expect (dropped.reason):toBe ("nan")
        expect (dropped.name):toBe ("__drop_test")

        Gate.onPlayerRemoved (player)
        Gate.onDrop (nil :: any)
    end)
end)

return nil
