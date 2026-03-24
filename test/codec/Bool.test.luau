--!strict
--!optimize 2
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe("Bool", function(): ()
    it("true round-trips", function(): () expect(roundTrip(Lync.bool, true)):toBe(true) end)
    it("false round-trips", function(): () expect(roundTrip(Lync.bool, false)):toBe(false) end)
    it("_size = 1", function(): () expect((Lync.bool :: any)._size):toBe(1) end)
    it("_isBool = true", function(): () expect((Lync.bool :: any)._isBool):toBe(true) end)
    it("_typeCheck = boolean", function(): () expect((Lync.bool :: any)._typeCheck):toBe("boolean") end)
    it("has _directWrite", function(): () expect((Lync.bool :: any)._directWrite):toBeTruthy() end)
    it("has _directRead", function(): () expect((Lync.bool :: any)._directRead):toBeTruthy() end)
    it("wire = 1 byte", function(): () local _, w = roundTrip(Lync.bool, true); expect(w):toBe(1) end)
end)

return nil
