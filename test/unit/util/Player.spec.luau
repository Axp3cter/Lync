--!strict
--!optimize 2
-- util.Player.is: Instance + IsA("Player") guard.

local Env = require(script:FindFirstAncestor("test").Env)

local Player = Env.Internal.Player
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach
local afterEach = Env.afterEach

describe("util.Player", function(): ()
    local instances: { Instance } = {}

    beforeEach(function(): ()
        Sandbox.resetAll()
        table.clear(instances)
    end)

    afterEach(function(): ()
        for _, inst in instances do
            inst:Destroy()
        end
        table.clear(instances)
    end)

    describe("is: non-Instance values", function(): ()
        it("returns false for nil", function(): ()
            expect(Player.is(nil)):toBe(false)
        end)
        it("returns false for empty table", function(): ()
            expect(Player.is({})):toBe(false)
        end)
        it("returns false for table with Class-like fields", function(): ()
            expect(Player.is({ ClassName = "Player", Name = "fake" })):toBe(false)
        end)
        it("returns false for number 0", function(): ()
            expect(Player.is(0)):toBe(false)
        end)
        it("returns false for number 42", function(): ()
            expect(Player.is(42)):toBe(false)
        end)
        it("returns false for negative number", function(): ()
            expect(Player.is(-1)):toBe(false)
        end)
        it("returns false for NaN", function(): ()
            expect(Player.is(0 / 0)):toBe(false)
        end)
        it("returns false for inf", function(): ()
            expect(Player.is(math.huge)):toBe(false)
        end)
        it("returns false for empty string", function(): ()
            expect(Player.is("")):toBe(false)
        end)
        it("returns false for arbitrary string", function(): ()
            expect(Player.is("Player")):toBe(false)
        end)
        it("returns false for true", function(): ()
            expect(Player.is(true)):toBe(false)
        end)
        it("returns false for false", function(): ()
            expect(Player.is(false)):toBe(false)
        end)
        it("returns false for function", function(): ()
            expect(Player.is(function() end)):toBe(false)
        end)
        it("returns false for buffer", function(): ()
            expect(Player.is(buffer.create(4))):toBe(false)
        end)
        it("returns false for Vector3", function(): ()
            expect(Player.is(Vector3.new(0, 0, 0))):toBe(false)
        end)
        it("returns false for CFrame", function(): ()
            expect(Player.is(CFrame.new())):toBe(false)
        end)
    end)

    describe("is: non-Player Instances", function(): ()
        it("returns false for Folder", function(): ()
            local f = Instance.new("Folder")
            table.insert(instances, f)
            expect(Player.is(f)):toBe(false)
        end)
        it("returns false for Part", function(): ()
            local p = Instance.new("Part")
            table.insert(instances, p)
            expect(Player.is(p)):toBe(false)
        end)
        it("returns false for Model", function(): ()
            local m = Instance.new("Model")
            table.insert(instances, m)
            expect(Player.is(m)):toBe(false)
        end)
        it("returns false for ScreenGui", function(): ()
            local g = Instance.new("ScreenGui")
            table.insert(instances, g)
            expect(Player.is(g)):toBe(false)
        end)
        it("returns false for RemoteEvent", function(): ()
            local r = Instance.new("RemoteEvent")
            table.insert(instances, r)
            expect(Player.is(r)):toBe(false)
        end)
        it("returns false for parented child", function(): ()
            local parent = Instance.new("Folder")
            local child = Instance.new("Folder")
            child.Parent = parent
            table.insert(instances, parent)
            expect(Player.is(child)):toBe(false)
        end)
    end)

    --[[
        We can't construct a real Player from user code, so the positive case
        is covered at integration scope through Players service interactions.
        This unit spec asserts every negative the production code relies on.
    ]]
end)

return nil
