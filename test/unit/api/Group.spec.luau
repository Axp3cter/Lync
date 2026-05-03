--!strict
--!optimize 2
-- api.Group: named player sets with __iter and PlayerRemoving cleanup tracking.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach
local afterEach = Env.afterEach

describe("api.Group", function(): ()
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

    local function fakePlayer(): Instance
        local f = Instance.new("Folder")
        table.insert(instances, f)
        return f
    end

    describe("add / remove / has / count", function(): ()
        it("add returns true the first time", function(): ()
            local g = Lync.group("g")
            expect(g:add(fakePlayer() :: any)):toBe(true)
        end)
        it("add returns false on duplicate", function(): ()
            local g = Lync.group("g")
            local p = fakePlayer()
            g:add(p :: any)
            expect(g:add(p :: any)):toBe(false)
        end)
        it("remove returns true if present", function(): ()
            local g = Lync.group("g")
            local p = fakePlayer()
            g:add(p :: any)
            expect(g:remove(p :: any)):toBe(true)
        end)
        it("remove returns false if absent", function(): ()
            local g = Lync.group("g")
            expect(g:remove(fakePlayer() :: any)):toBe(false)
        end)
        it("has true after add", function(): ()
            local g = Lync.group("g")
            local p = fakePlayer()
            g:add(p :: any)
            expect(g:has(p :: any)):toBe(true)
        end)
        it("has false after remove", function(): ()
            local g = Lync.group("g")
            local p = fakePlayer()
            g:add(p :: any)
            g:remove(p :: any)
            expect(g:has(p :: any)):toBe(false)
        end)
        it("has false for never-added", function(): ()
            local g = Lync.group("g")
            expect(g:has(fakePlayer() :: any)):toBe(false)
        end)
        it("count starts at 0", function(): ()
            expect(Lync.group("g"):count()):toBe(0)
        end)
        it("count increments on add", function(): ()
            local g = Lync.group("g")
            g:add(fakePlayer() :: any)
            g:add(fakePlayer() :: any)
            expect(g:count()):toBe(2)
        end)
        it("count decrements on remove", function(): ()
            local g = Lync.group("g")
            local p1 = fakePlayer()
            g:add(p1 :: any)
            g:add(fakePlayer() :: any)
            g:remove(p1 :: any)
            expect(g:count()):toBe(1)
        end)
        it("duplicate add does not inflate count", function(): ()
            local g = Lync.group("g")
            local p = fakePlayer()
            g:add(p :: any)
            g:add(p :: any)
            expect(g:count()):toBe(1)
        end)
    end)

    describe("__iter", function(): ()
        it("iterates all members", function(): ()
            local g = Lync.group("g")
            local p1 = fakePlayer()
            local p2 = fakePlayer()
            local p3 = fakePlayer()
            g:add(p1 :: any)
            g:add(p2 :: any)
            g:add(p3 :: any)
            local seen: { [any]: boolean } = {}
            for player in g do
                seen[player] = true
            end
            expect(seen[p1]):toBe(true)
            expect(seen[p2]):toBe(true)
            expect(seen[p3]):toBe(true)
        end)
        it("empty group iterates zero times", function(): ()
            local g = Lync.group("g")
            local count = 0
            for _ in g do
                count += 1
            end
            expect(count):toBe(0)
        end)
        it("single member yields once", function(): ()
            local g = Lync.group("g")
            local p = fakePlayer()
            g:add(p :: any)
            local count = 0
            local seen: any = nil
            for player in g do
                count += 1
                seen = player
            end
            expect(count):toBe(1)
            expect(seen):toBe(p)
        end)
    end)

    describe("destroy", function(): ()
        it("clears all members", function(): ()
            local g = Lync.group("g")
            g:add(fakePlayer() :: any)
            g:add(fakePlayer() :: any)
            g:destroy()
            expect(g:count()):toBe(0)
        end)
        it("frees the name for reuse", function(): ()
            expect(function(): ()
                Lync.group("reuse"):destroy()
                Lync.group("reuse"):destroy()
            end).never:toThrow()
        end)
        it("double destroy is safe", function(): ()
            local g = Lync.group("g")
            expect(function(): ()
                g:destroy()
                g:destroy()
            end).never:toThrow()
        end)
    end)

    describe("duplicate name throws", function(): ()
        it("second create with same name throws", function(): ()
            Lync.group("dup")
            expect(function(): ()
                Lync.group("dup")
            end):toThrow("already exists")
        end)
    end)
end)

return nil
