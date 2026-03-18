--!strict
--!optimize 2
local Gate = require(script.Parent.Parent.Parent.transport.Gate)
local Lync = require(script.Parent.Parent.Parent)
local Registry = require(script.Parent.Parent.Parent.internal.Registry)
local Runner = require(script.Parent.Parent.Runner)
local Signal = require(script.Parent.Parent.Parent.api.Signal)
local describe, it, expect, fakePlayer =
    Runner.describe, Runner.it, Runner.expect, Runner.fakePlayer

local nan = 0 / 0

local function makeReg(): any
    return {
        id = 90000,
        name = "__gate",
        baseName = "__gate",
        codec = Lync.u8,
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

describe("Gate.isClean primitives", function(): ()
    local p = fakePlayer("GateP", 2000)
    Gate.onPlayerAdded(p)
    local reg = makeReg()

    it("accepts number", function(): ()
        expect(Gate.check(42, reg, p)):toBe(true)
    end)
    it("accepts string", function(): ()
        expect(Gate.check("hi", reg, p)):toBe(true)
    end)
    it("accepts bool", function(): ()
        expect(Gate.check(true, reg, p)):toBe(true)
    end)
    it("accepts nil", function(): ()
        expect(Gate.check(nil, reg, p)):toBe(true)
    end)
    it("rejects NaN", function(): ()
        expect(Gate.check(nan, reg, p)):toBe(false)
    end)
    it("rejects inf", function(): ()
        expect(Gate.check(math.huge, reg, p)):toBe(false)
    end)
    it("rejects -inf", function(): ()
        expect(Gate.check(-math.huge, reg, p)):toBe(false)
    end)

    Gate.onPlayerRemoved(p)
end)

describe("Gate.isClean Vector2", function(): ()
    local p = fakePlayer("GateV2", 2001)
    Gate.onPlayerAdded(p)
    local reg = makeReg()

    it("accepts clean", function(): ()
        expect(Gate.check(Vector2.new(1, 2), reg, p)):toBe(true)
    end)
    it("rejects NaN X", function(): ()
        expect(Gate.check(Vector2.new(nan, 0), reg, p)):toBe(false)
    end)
    it("rejects NaN Y", function(): ()
        expect(Gate.check(Vector2.new(0, nan), reg, p)):toBe(false)
    end)

    Gate.onPlayerRemoved(p)
end)

describe("Gate.isClean Vector3", function(): ()
    local p = fakePlayer("GateV3", 2002)
    Gate.onPlayerAdded(p)
    local reg = makeReg()

    it("accepts clean", function(): ()
        expect(Gate.check(Vector3.new(1, 2, 3), reg, p)):toBe(true)
    end)
    it("rejects NaN", function(): ()
        expect(Gate.check(Vector3.new(0, nan, 0), reg, p)):toBe(false)
    end)

    Gate.onPlayerRemoved(p)
end)

describe("Gate.isClean Color3", function(): ()
    local p = fakePlayer("GateC3", 2003)
    Gate.onPlayerAdded(p)
    local reg = makeReg()

    it("accepts clean", function(): ()
        expect(Gate.check(Color3.new(1, 0, 0), reg, p)):toBe(true)
    end)
    it("rejects NaN", function(): ()
        expect(Gate.check(Color3.new(nan, 0, 0), reg, p)):toBe(false)
    end)

    Gate.onPlayerRemoved(p)
end)

describe("Gate.isClean UDim/UDim2", function(): ()
    local p = fakePlayer("GateU", 2004)
    Gate.onPlayerAdded(p)
    local reg = makeReg()

    it("accepts clean UDim", function(): ()
        expect(Gate.check(UDim.new(0.5, 10), reg, p)):toBe(true)
    end)
    it("rejects NaN UDim", function(): ()
        expect(Gate.check(UDim.new(nan, 0), reg, p)):toBe(false)
    end)
    it("accepts clean UDim2", function(): ()
        expect(Gate.check(UDim2.new(UDim.new(0.5, 10), UDim.new(1, 20)), reg, p)):toBe(true)
    end)
    it("rejects NaN UDim2", function(): ()
        expect(Gate.check(UDim2.new(UDim.new(nan, 0), UDim.new(0, 0)), reg, p)):toBe(false)
    end)

    Gate.onPlayerRemoved(p)
end)

describe("Gate.isClean NumberRange/Rect", function(): ()
    local p = fakePlayer("GateNR", 2005)
    Gate.onPlayerAdded(p)
    local reg = makeReg()

    it("accepts clean NR", function(): ()
        expect(Gate.check(NumberRange.new(0, 1), reg, p)):toBe(true)
    end)
    it("rejects NaN NR", function(): ()
        expect(Gate.check(NumberRange.new(nan, 1), reg, p)):toBe(false)
    end)
    it("accepts clean Rect", function(): ()
        expect(Gate.check(Rect.new(0, 0, 100, 100), reg, p)):toBe(true)
    end)
    it("rejects NaN Rect", function(): ()
        expect(Gate.check(Rect.new(nan, 0, 1, 1), reg, p)):toBe(false)
    end)

    Gate.onPlayerRemoved(p)
end)

describe("Gate.isClean Ray", function(): ()
    local p = fakePlayer("GateRay", 2006)
    Gate.onPlayerAdded(p)
    local reg = makeReg()

    it("accepts clean", function(): ()
        expect(Gate.check(Ray.new(Vector3.one, Vector3.yAxis), reg, p)):toBe(true)
    end)
    it("rejects NaN origin", function(): ()
        expect(Gate.check(Ray.new(Vector3.new(nan, 0, 0), Vector3.yAxis), reg, p)):toBe(false)
    end)
    it("rejects NaN dir", function(): ()
        expect(Gate.check(Ray.new(Vector3.zero, Vector3.new(0, nan, 0)), reg, p)):toBe(false)
    end)

    Gate.onPlayerRemoved(p)
end)

describe("Gate.isClean Region3", function(): ()
    local p = fakePlayer("GateReg", 2007)
    Gate.onPlayerAdded(p)
    local reg = makeReg()

    it("accepts clean", function(): ()
        expect(Gate.check(Region3.new(Vector3.zero, Vector3.one), reg, p)):toBe(true)
    end)
    it("rejects NaN", function(): ()
        expect(Gate.check(Region3.new(Vector3.new(nan, 0, 0), Vector3.one), reg, p)):toBe(false)
    end)

    Gate.onPlayerRemoved(p)
end)

describe("Gate.isClean tables", function(): ()
    local p = fakePlayer("GateT", 2008)
    Gate.onPlayerAdded(p)
    local reg = makeReg()

    it("accepts clean table", function(): ()
        expect(Gate.check({ x = 1, y = "hi" }, reg, p)):toBe(true)
    end)
    it("rejects NaN in value", function(): ()
        expect(Gate.check({ x = nan }, reg, p)):toBe(false)
    end)
    it("rejects deep NaN", function(): ()
        expect(Gate.check({ a = { b = { c = nan } } }, reg, p)):toBe(false)
    end)

    Gate.onPlayerRemoved(p)
end)

describe("Gate validate callback", function(): ()
    local p = fakePlayer("GateVal", 2009)
    Gate.onPlayerAdded(p)

    it("blocks when validate returns false", function(): ()
        local reg = makeReg()
        reg.validate = function(): (boolean, string?)
            return false, "blocked"
        end
        reg.needsGate = true
        expect(Gate.check(42, reg, p)):toBe(false)
    end)
    it("allows when validate returns true", function(): ()
        local reg = makeReg()
        reg.validate = function(): (boolean, string?)
            return true, nil
        end
        reg.needsGate = true
        expect(Gate.check(42, reg, p)):toBe(true)
    end)

    Gate.onPlayerRemoved(p)
end)

describe("Gate depth limit", function(): ()
    it("set and get", function(): ()
        local old = Gate.getMaxDepth()
        Gate.setMaxDepth(5)
        expect(Gate.getMaxDepth()):toBe(5)
        Gate.setMaxDepth(old)
    end)
end)

describe("Gate onDrop callback", function(): ()
    it("fires on drop", function(): ()
        local fired = false
        local remove = Gate.onDrop(function(): ()
            fired = true
        end)
        local p = fakePlayer("GateDrop", 2010)
        Gate.onPlayerAdded(p)
        Gate.reportDrop(p, "test", "__drop", nil)
        expect(fired):toBe(true)
        remove()
        Gate.onPlayerRemoved(p)
    end)
end)

describe("Gate onDrop multiple handlers", function(): ()
    it("fires all handlers", function(): ()
        local a, b = 0, 0
        local ra = Gate.onDrop(function(): ()
            a += 1
        end)
        local rb = Gate.onDrop(function(): ()
            b += 1
        end)
        local p = fakePlayer("GateMulti", 2020)
        Gate.onPlayerAdded(p)
        Gate.reportDrop(p, "test", "__multi", nil)
        expect(a):toBe(1)
        expect(b):toBe(1)
        ra()
        rb()
        Gate.onPlayerRemoved(p)
    end)
    it("remover stops handler", function(): ()
        local count = 0
        local remove = Gate.onDrop(function(): ()
            count += 1
        end)
        local p = fakePlayer("GateRm", 2021)
        Gate.onPlayerAdded(p)
        Gate.reportDrop(p, "test", "__rm", nil)
        expect(count):toBe(1)
        remove()
        Gate.reportDrop(p, "test", "__rm", nil)
        expect(count):toBe(1)
        Gate.onPlayerRemoved(p)
    end)
    it("double remove safe", function(): ()
        local remove = Gate.onDrop(function(): () end)
        remove()
        remove()
    end)
end)

return nil
