--!strict
--!optimize 2
-- util.Array.swapRemove: O(1) swap-with-last array remove.

local Env = require(script:FindFirstAncestor("test").Env)

local Array = Env.Internal.Array
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("util.Array.swapRemove", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("single-element arrays", function(): ()
        it("removes the only element", function(): ()
            local arr = { "a" }
            Array.swapRemove(arr, 1)
            expect(#arr):toBe(0)
            expect(arr[1]):toBe(nil)
        end)
        it("removing the only number element clears the slot", function(): ()
            local arr = { 42 }
            Array.swapRemove(arr, 1)
            expect(#arr):toBe(0)
        end)
        it("removing the only Instance element clears the slot", function(): ()
            local f = Instance.new("Folder")
            local arr = { f }
            Array.swapRemove(arr, 1)
            expect(#arr):toBe(0)
            f:Destroy()
        end)
    end)

    describe("removal from end (no swap needed)", function(): ()
        it("removes last of 2", function(): ()
            local arr = { "a", "b" }
            Array.swapRemove(arr, 2)
            expect(#arr):toBe(1)
            expect(arr[1]):toBe("a")
        end)
        it("removes last of 3", function(): ()
            local arr = { "a", "b", "c" }
            Array.swapRemove(arr, 3)
            expect(#arr):toBe(2)
            expect(arr[1]):toBe("a")
            expect(arr[2]):toBe("b")
        end)
        it("removes last of 10", function(): ()
            local arr = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }
            Array.swapRemove(arr, 10)
            expect(#arr):toBe(9)
            expect(arr[9]):toBe(9)
            expect(arr[10]):toBe(nil)
        end)
    end)

    describe("removal from middle (swap-with-last)", function(): ()
        it("removes middle of 3 swaps last in", function(): ()
            local arr = { "a", "b", "c" }
            Array.swapRemove(arr, 2)
            expect(#arr):toBe(2)
            expect(arr[1]):toBe("a")
            expect(arr[2]):toBe("c")
        end)
        it("removes index 2 of 4 places original last (4) at index 2", function(): ()
            local arr = { "a", "b", "c", "d" }
            Array.swapRemove(arr, 2)
            expect(#arr):toBe(3)
            expect(arr[1]):toBe("a")
            expect(arr[2]):toBe("d")
            expect(arr[3]):toBe("c")
        end)
        it("removes index 3 of 5", function(): ()
            local arr = { 10, 20, 30, 40, 50 }
            Array.swapRemove(arr, 3)
            expect(#arr):toBe(4)
            expect(arr[3]):toBe(50)
        end)
    end)

    describe("removal from front", function(): ()
        it("removes first of 4 places last (4) at index 1", function(): ()
            local arr = { 10, 20, 30, 40 }
            Array.swapRemove(arr, 1)
            expect(#arr):toBe(3)
            expect(arr[1]):toBe(40)
            expect(arr[2]):toBe(20)
            expect(arr[3]):toBe(30)
        end)
        it("removes first of 2 leaves the original second", function(): ()
            local arr = { "x", "y" }
            Array.swapRemove(arr, 1)
            expect(#arr):toBe(1)
            expect(arr[1]):toBe("y")
        end)
    end)

    describe("ordering invariants", function(): ()
        it("does not preserve insertion order (intentional)", function(): ()
            local arr = { 1, 2, 3, 4, 5, 6, 7, 8 }
            Array.swapRemove(arr, 4)
            expect(arr[4]):toBe(8)
            expect(arr[5]):toBe(5)
            expect(arr[6]):toBe(6)
            expect(arr[7]):toBe(7)
        end)
        it("preserves leading elements before the removed index", function(): ()
            local arr = { 1, 2, 3, 4, 5 }
            Array.swapRemove(arr, 5)
            expect(arr[1]):toBe(1)
            expect(arr[2]):toBe(2)
            expect(arr[3]):toBe(3)
            expect(arr[4]):toBe(4)
        end)
    end)

    describe("repeated removals", function(): ()
        it("can drain a 5-element array via repeated removeAt 1", function(): ()
            local arr = { 1, 2, 3, 4, 5 }
            for _ = 1, 5 do
                Array.swapRemove(arr, 1)
            end
            expect(#arr):toBe(0)
        end)
        it("can drain via repeated removeAt #arr (LIFO)", function(): ()
            local arr = { "a", "b", "c", "d" }
            while #arr > 0 do
                Array.swapRemove(arr, #arr)
            end
            expect(#arr):toBe(0)
        end)
    end)

    describe("mixed-type arrays", function(): ()
        it("mixed strings and numbers swap correctly", function(): ()
            local arr: { any } = { "a", 1, "b", 2 }
            Array.swapRemove(arr, 2)
            expect(#arr):toBe(3)
            expect(arr[2]):toBe(2)
        end)
        it("preserves table references on swap", function(): ()
            local t1 = { id = 1 }
            local t2 = { id = 2 }
            local t3 = { id = 3 }
            local arr = { t1, t2, t3 }
            Array.swapRemove(arr, 1)
            expect(arr[1]):toBe(t3)
            expect(arr[2]):toBe(t2)
        end)
    end)

    describe("return shape", function(): ()
        it("returns no values (operates in place)", function(): ()
            local arr = { 1, 2, 3 }
            local result = Array.swapRemove(arr, 1)
            expect(result):toBe(nil)
        end)
    end)
end)

return nil
