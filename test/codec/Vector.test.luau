--!strict
--!optimize 2
local Runner = require(script.Parent.Parent.Runner)
local Lync   = require(script.Parent.Parent.Parent)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe("Vector.vec2", function(): ()
    it("round-trips origin",    function(): () local r = roundTrip(Lync.vec2, Vector2.new(0, 0)); expect(r.X):toBe(0); expect(r.Y):toBe(0) end)
    it("round-trips positive",  function(): () local r = roundTrip(Lync.vec2, Vector2.new(1.5, 2.5)); expect(r.X):toBeCloseTo(1.5); expect(r.Y):toBeCloseTo(2.5) end)
    it("round-trips negative",  function(): () local r = roundTrip(Lync.vec2, Vector2.new(-100, -200)); expect(r.X):toBeCloseTo(-100); expect(r.Y):toBeCloseTo(-200) end)
    it("round-trips large",     function(): () local r = roundTrip(Lync.vec2, Vector2.new(1e6, -1e6)); expect(r.X):toBeCloseTo(1e6, 100); expect(r.Y):toBeCloseTo(-1e6, 100) end)
    it("round-trips very small", function(): () local r = roundTrip(Lync.vec2, Vector2.new(1e-10, -1e-10)); expect(r.X):toBeCloseTo(1e-10, 1e-15); expect(r.Y):toBeCloseTo(-1e-10, 1e-15) end)
    it("round-trips one",       function(): () local r = roundTrip(Lync.vec2, Vector2.one); expect(r.X):toBe(1); expect(r.Y):toBe(1) end)
    it("uses 8 bytes",          function(): () local _, w = roundTrip(Lync.vec2, Vector2.new(1, 2)); expect(w):toBe(8) end)
    it("_size is 8",            function(): () expect((Lync.vec2 :: any)._size):toBe(8) end)
end)

describe("Vector.vec3", function(): ()
    it("round-trips origin",    function(): () local r = roundTrip(Lync.vec3, Vector3.zero); expect(r.X):toBe(0); expect(r.Y):toBe(0); expect(r.Z):toBe(0) end)
    it("round-trips positive",  function(): () local r = roundTrip(Lync.vec3, Vector3.new(10, 20, 30)); expect(r.X):toBeCloseTo(10); expect(r.Y):toBeCloseTo(20); expect(r.Z):toBeCloseTo(30) end)
    it("round-trips negative",  function(): () local r = roundTrip(Lync.vec3, Vector3.new(-1.5, -2.5, -3.5)); expect(r.X):toBeCloseTo(-1.5); expect(r.Y):toBeCloseTo(-2.5); expect(r.Z):toBeCloseTo(-3.5) end)
    it("round-trips large",     function(): () local r = roundTrip(Lync.vec3, Vector3.new(1e6, 0, -1e6)); expect(r.X):toBeCloseTo(1e6, 100); expect(r.Z):toBeCloseTo(-1e6, 100) end)
    it("round-trips one",       function(): () local r = roundTrip(Lync.vec3, Vector3.one); expect(r.X):toBe(1); expect(r.Y):toBe(1); expect(r.Z):toBe(1) end)
    it("round-trips mixed signs", function(): () local r = roundTrip(Lync.vec3, Vector3.new(-1, 0, 1)); expect(r.X):toBe(-1); expect(r.Y):toBe(0); expect(r.Z):toBe(1) end)
    it("uses 12 bytes",         function(): () local _, w = roundTrip(Lync.vec3, Vector3.new(1, 2, 3)); expect(w):toBe(12) end)
    it("_size is 12",           function(): () expect((Lync.vec3 :: any)._size):toBe(12) end)
end)

return nil
