--!strict
--!optimize 2
-- Group.test.luau — Named player set create/destroy/add/remove/iterate tests.

local Runner = require(script.Parent.Parent.Runner)
local Group  = require(script.Parent.Parent.Parent.event.Group)

local describe   = Runner.describe
local it         = Runner.it
local expect     = Runner.expect
local fakePlayer = Runner.fakePlayer

-- Tests ------------------------------------------------------------------

describe("Group.create + destroy", function(): ()
    it("creates a group that can be destroyed", function(): ()
        Group.create("__test_lifecycle")
        expect(function(): ()
            Group.destroy("__test_lifecycle")
        end).never:toThrow()
    end)
    it("throws on duplicate create", function(): ()
        Group.create("__test_dup_create")
        expect(function(): ()
            Group.create("__test_dup_create")
        end):toThrow("already exists")
        Group.destroy("__test_dup_create")
    end)
    it("throws on destroying nonexistent group", function(): ()
        expect(function(): ()
            Group.destroy("__test_nonexistent")
        end):toThrow("does not exist")
    end)
end)

describe("Group.add + remove + players", function(): ()
    it("adds and retrieves players", function(): ()
        Group.create("__test_members")
        local playerA = fakePlayer("Alice", 1)
        local playerB = fakePlayer("Bob", 2)

        Group.add("__test_members", playerA)
        Group.add("__test_members", playerB)

        local list = Group.players("__test_members")
        expect(#list):toBe(2)

        Group.destroy("__test_members")
    end)
    it("removes a player", function(): ()
        Group.create("__test_remove")
        local player = fakePlayer("Alice", 1)

        Group.add("__test_remove", player)
        Group.remove("__test_remove", player)

        local list = Group.players("__test_remove")
        expect(#list):toBe(0)

        Group.destroy("__test_remove")
    end)
    it("throws on add to nonexistent group", function(): ()
        expect(function(): ()
            Group.add("__test_ghost", fakePlayer("A", 1))
        end):toThrow("does not exist")
    end)
end)

describe("Group.forEach", function(): ()
    it("iterates over all members", function(): ()
        Group.create("__test_forEach")
        local playerA = fakePlayer("Alice", 1)
        local playerB = fakePlayer("Bob", 2)
        Group.add("__test_forEach", playerA)
        Group.add("__test_forEach", playerB)

        local visited = 0
        Group.forEach("__test_forEach", function(_player: Player): ()
            visited += 1
        end)
        expect(visited):toBe(2)

        Group.destroy("__test_forEach")
    end)
    it("throws on nonexistent group", function(): ()
        expect(function(): ()
            Group.forEach("__test_nogroup", function(): () end)
        end):toThrow("does not exist")
    end)
end)

return nil
