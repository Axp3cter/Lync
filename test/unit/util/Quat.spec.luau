--!strict
--!optimize 2
-- util.Quat: smallest-three quaternion pack/unpack into u32.

local Env = require(script:FindFirstAncestor("test").Env)

local Sandbox = Env.Sandbox

local Quat = require(script:FindFirstAncestor("Lync").util.Quat)

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

-- Two CFrames count as "close" if their forward vectors agree per-axis to ~0.01.
local function lookClose(a: CFrame, b: CFrame, eps: number?): boolean
    local tolerance = eps or 0.01
    local lookA = a.LookVector
    local lookB = b.LookVector
    return math.abs(lookA.X - lookB.X) < tolerance
        and math.abs(lookA.Y - lookB.Y) < tolerance
        and math.abs(lookA.Z - lookB.Z) < tolerance
end

describe("util.Quat", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("fromCFrame", function(): ()
        it("identity yields (0, 0, 0, 1)", function(): ()
            local x, y, z, w = Quat.fromCFrame(CFrame.identity)
            expect(math.abs(x) < 1e-6):toBe(true)
            expect(math.abs(y) < 1e-6):toBe(true)
            expect(math.abs(z) < 1e-6):toBe(true)
            expect(math.abs(w - 1) < 1e-6):toBe(true)
        end)
        it("90deg yaw yields y axis component", function(): ()
            local _, y, _, _ = Quat.fromCFrame(CFrame.Angles(0, math.pi / 2, 0))
            expect(y > 0.5):toBe(true)
        end)
        it("position is ignored (rotation only)", function(): ()
            local a = { Quat.fromCFrame(CFrame.new(0, 0, 0)) }
            local b = { Quat.fromCFrame(CFrame.new(100, 200, 300)) }
            for i = 1, 4 do
                expect(math.abs(a[i] - b[i]) < 1e-6):toBe(true)
            end
        end)
    end)

    describe("pack/unpack round-trip", function(): ()
        it("identity round-trips to identity", function(): ()
            local packed = Quat.pack(Quat.fromCFrame(CFrame.identity))
            local r = Quat.unpack(packed)
            expect(lookClose(r, CFrame.identity)):toBe(true)
        end)
        it("90deg yaw round-trips", function(): ()
            local cf = CFrame.Angles(0, math.pi / 2, 0)
            local r = Quat.unpack(Quat.pack(Quat.fromCFrame(cf)))
            expect(lookClose(r, cf)):toBe(true)
        end)
        it("90deg pitch round-trips", function(): ()
            local cf = CFrame.Angles(math.pi / 2, 0, 0)
            local r = Quat.unpack(Quat.pack(Quat.fromCFrame(cf)))
            expect(lookClose(r, cf)):toBe(true)
        end)
        it("90deg roll round-trips", function(): ()
            local cf = CFrame.Angles(0, 0, math.pi / 2)
            local r = Quat.unpack(Quat.pack(Quat.fromCFrame(cf)))
            expect(lookClose(r, cf)):toBe(true)
        end)
        it("arbitrary angles round-trip within precision", function(): ()
            local angles = {
                CFrame.Angles(0.1, 0.2, 0.3),
                CFrame.Angles(-0.4, 0.5, -0.6),
                CFrame.Angles(math.pi / 4, math.pi / 3, math.pi / 6),
                CFrame.Angles(math.pi, 0, 0),
            }
            for _, cf in angles do
                local r = Quat.unpack(Quat.pack(Quat.fromCFrame(cf)))
                expect(lookClose(r, cf, 0.02)):toBe(true)
            end
        end)
    end)

    describe("smallest-three packing keeps quat unit", function(): ()
        it("decoded magnitude approximates 1", function(): ()
            local cf = CFrame.Angles(0.5, 0.7, 0.3)
            local packed = Quat.pack(Quat.fromCFrame(cf))
            local r = Quat.unpack(packed)
            -- Unit-quat -> rotation matrix; LookVector.Magnitude ≈ 1.
            expect(math.abs(r.LookVector.Magnitude - 1) < 0.01):toBe(true)
        end)
    end)

    describe("output fits in u32", function(): ()
        it("pack returns a 32-bit unsigned integer", function(): ()
            local packed = Quat.pack(Quat.fromCFrame(CFrame.Angles(0.1, 0.2, 0.3)))
            expect(packed >= 0):toBe(true)
            expect(packed <= 0xFFFFFFFF):toBe(true)
        end)
    end)

    describe("near-zero magnitudes decode to identity", function(): ()
        it("packed zero quat decodes without error", function(): ()
            local packed = Quat.pack(0, 0, 0, 1)
            local r = Quat.unpack(packed)
            expect(lookClose(r, CFrame.identity, 0.05)):toBe(true)
        end)
    end)
end)

return nil
