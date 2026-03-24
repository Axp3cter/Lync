--!strict
--!optimize 2
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe("tuple", function(): ()
    it("single element", function(): ()
        local r = roundTrip(Lync.tuple(Lync.int(0, 255)), { 42 })
        expect(r[1]):toBe(42)
    end)
    it("two elements", function(): ()
        local r = roundTrip(Lync.tuple(Lync.int(0, 255), Lync.string), { 42, "hello" })
        expect(r[1]):toBe(42)
        expect(r[2]):toBe("hello")
    end)
    it("five elements", function(): ()
        local c = Lync.tuple(
            Lync.int(0, 255),
            Lync.int(0, 255),
            Lync.int(0, 255),
            Lync.int(0, 255),
            Lync.int(0, 255)
        )
        local r = roundTrip(c, { 1, 2, 3, 4, 5 })
        expect(r[1]):toBe(1)
        expect(r[5]):toBe(5)
    end)
    it("all-direct exposes _size", function(): ()
        expect((Lync.tuple(Lync.int(0, 255), Lync.int(0, 65535)) :: any)._size):toBe(3)
    end)
    it("mixed has no _size", function(): ()
        expect((Lync.tuple(Lync.int(0, 255), Lync.string) :: any)._size):toBeNil()
    end)
    it("all-direct has _directWrite", function(): ()
        expect((Lync.tuple(Lync.int(0, 255)) :: any)._directWrite):toBeTruthy()
    end)
    it("empty errors", function(): ()
        expect(function(): ()
            Lync.tuple()
        end):toThrow("at least one")
    end)
    it("nested tuple", function(): ()
        local inner = Lync.tuple(Lync.int(0, 255), Lync.int(0, 255))
        local outer = Lync.tuple(inner, Lync.string)
        local r = roundTrip(outer, { { 1, 2 }, "hi" })
        expect(r[1][1]):toBe(1)
        expect(r[1][2]):toBe(2)
        expect(r[2]):toBe("hi")
    end)
end)

return nil
