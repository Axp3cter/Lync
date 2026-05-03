--!strict
--!optimize 2
-- Lync.vec2int16 (4 bytes) and Lync.vec3int16 (6 bytes).

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.datatype.IntVector", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("vec2int16", function(): ()
        it("_size = 4", function(): ()
            expect((Lync.vec2int16 :: any)._size):toBe(4)
        end)
        it("_typeCheck = Vector2int16", function(): ()
            expect((Lync.vec2int16 :: any)._typeCheck):toBe("Vector2int16")
        end)
        it("positive components round-trip", function(): ()
            local r = Channel.roundTripStrict(Lync.vec2int16, Vector2int16.new(100, 200))
            expect(r.X):toBe(100)
            expect(r.Y):toBe(200)
        end)
        it("negative components round-trip", function(): ()
            local r = Channel.roundTripStrict(Lync.vec2int16, Vector2int16.new(-100, -200))
            expect(r.X):toBe(-100)
            expect(r.Y):toBe(-200)
        end)
        it("i16 boundary values", function(): ()
            local r = Channel.roundTripStrict(Lync.vec2int16, Vector2int16.new(-32768, 32767))
            expect(r.X):toBe(-32768)
            expect(r.Y):toBe(32767)
        end)
        it("zero", function(): ()
            local r = Channel.roundTripStrict(Lync.vec2int16, Vector2int16.new(0, 0))
            expect(r.X):toBe(0)
            expect(r.Y):toBe(0)
        end)
    end)

    describe("vec3int16", function(): ()
        it("_size = 6", function(): ()
            expect((Lync.vec3int16 :: any)._size):toBe(6)
        end)
        it("_typeCheck = Vector3int16", function(): ()
            expect((Lync.vec3int16 :: any)._typeCheck):toBe("Vector3int16")
        end)
        it("positive components", function(): ()
            local r = Channel.roundTripStrict(Lync.vec3int16, Vector3int16.new(10, 20, 30))
            expect(r.X):toBe(10)
            expect(r.Y):toBe(20)
            expect(r.Z):toBe(30)
        end)
        it("negative components", function(): ()
            local r = Channel.roundTripStrict(Lync.vec3int16, Vector3int16.new(-10, -20, -30))
            expect(r.X):toBe(-10)
            expect(r.Z):toBe(-30)
        end)
        it("i16 boundary values", function(): ()
            local r = Channel.roundTripStrict(Lync.vec3int16, Vector3int16.new(-32768, 0, 32767))
            expect(r.X):toBe(-32768)
            expect(r.Z):toBe(32767)
        end)
    end)
end)

return nil
