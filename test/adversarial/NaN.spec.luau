--!strict
--!optimize 2
-- NaN / inf rejection across Gate.scan and Gate.validate.

local Env = require(script:FindFirstAncestor("test").Env)

local Gate = Env.Internal.Gate
local Lync = Env.Lync
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

local nan = 0 / 0

describe("adversarial.NaN", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("Gate.scan: scalars", function(): ()
        local cases = {
            { name = "NaN", value = nan, ok = false },
            { name = "+inf", value = math.huge, ok = false },
            { name = "-inf", value = -math.huge, ok = false },
            { name = "clean number", value = 42, ok = true },
            { name = "zero", value = 0, ok = true },
            { name = "negative", value = -100, ok = true },
            { name = "string", value = "hello", ok = true },
            { name = "empty string", value = "", ok = true },
            { name = "true", value = true, ok = true },
            { name = "false", value = false, ok = true },
            { name = "nil", value = nil, ok = true },
        }
        for _, c in cases do
            it(c.name, function(): ()
                expect(Gate.scan(c.value)):toBe(c.ok)
            end)
        end
    end)

    describe("Gate.scan: Vector2", function(): ()
        it("clean", function(): ()
            expect(Gate.scan(Vector2.new(1, 2))):toBe(true)
        end)
        it("NaN X rejects", function(): ()
            expect(Gate.scan(Vector2.new(nan, 0))):toBe(false)
        end)
        it("NaN Y rejects", function(): ()
            expect(Gate.scan(Vector2.new(0, nan))):toBe(false)
        end)
        it("inf X rejects", function(): ()
            expect(Gate.scan(Vector2.new(math.huge, 0))):toBe(false)
        end)
    end)

    describe("Gate.scan: Vector3", function(): ()
        it("clean", function(): ()
            expect(Gate.scan(Vector3.new(1, 2, 3))):toBe(true)
        end)
        it("NaN X rejects", function(): ()
            expect(Gate.scan(Vector3.new(nan, 0, 0))):toBe(false)
        end)
        it("NaN Y rejects", function(): ()
            expect(Gate.scan(Vector3.new(0, nan, 0))):toBe(false)
        end)
        it("NaN Z rejects", function(): ()
            expect(Gate.scan(Vector3.new(0, 0, nan))):toBe(false)
        end)
    end)

    describe("Gate.scan: Color3", function(): ()
        it("clean", function(): ()
            expect(Gate.scan(Color3.new(1, 0, 0))):toBe(true)
        end)
        it("NaN R", function(): ()
            expect(Gate.scan(Color3.new(nan, 0, 0))):toBe(false)
        end)
        it("NaN G", function(): ()
            expect(Gate.scan(Color3.new(0, nan, 0))):toBe(false)
        end)
        it("NaN B", function(): ()
            expect(Gate.scan(Color3.new(0, 0, nan))):toBe(false)
        end)
    end)

    describe("Gate.scan: UDim / UDim2", function(): ()
        it("UDim NaN scale", function(): ()
            expect(Gate.scan(UDim.new(nan, 0))):toBe(false)
        end)
        it("UDim2 NaN X scale", function(): ()
            expect(Gate.scan(UDim2.new(UDim.new(nan, 0), UDim.new(0, 0)))):toBe(false)
        end)
    end)

    describe("Gate.scan: NumberRange / Rect / Ray", function(): ()
        it("NumberRange NaN min", function(): ()
            expect(Gate.scan(NumberRange.new(nan, 1))):toBe(false)
        end)
        it("NumberRange NaN max", function(): ()
            expect(Gate.scan(NumberRange.new(0, nan))):toBe(false)
        end)
        it("Rect NaN minX", function(): ()
            expect(Gate.scan(Rect.new(nan, 0, 1, 1))):toBe(false)
        end)
        it("Ray NaN origin", function(): ()
            expect(Gate.scan(Ray.new(Vector3.new(nan, 0, 0), Vector3.yAxis))):toBe(false)
        end)
        it("Ray NaN direction", function(): ()
            expect(Gate.scan(Ray.new(Vector3.zero, Vector3.new(0, nan, 0)))):toBe(false)
        end)
    end)

    describe("Gate.scan: CFrame", function(): ()
        it("clean", function(): ()
            expect(Gate.scan(CFrame.new(1, 2, 3))):toBe(true)
        end)
        it("NaN position rejects", function(): ()
            expect(Gate.scan(CFrame.new(nan, 0, 0))):toBe(false)
        end)
    end)

    describe("Gate.scan: tables", function(): ()
        it("clean nested", function(): ()
            expect(Gate.scan({ a = { b = { c = 42 } } })):toBe(true)
        end)
        it("deep NaN rejects", function(): ()
            expect(Gate.scan({ a = { b = { c = nan } } })):toBe(false)
        end)
        it("NaN in array position", function(): ()
            expect(Gate.scan({ 1, nan, 3 })):toBe(false)
        end)
        it("empty table", function(): ()
            expect(Gate.scan({})):toBe(true)
        end)
        it("mixed clean", function(): ()
            expect(Gate.scan({ 1, "hi", true, Vector3.zero })):toBe(true)
        end)
    end)

    describe("Gate.validate: int rejects NaN/inf", function(): ()
        it("rejects NaN", function(): ()
            expect(Gate.validate(nan, Lync.int(0, 100))).never:toBe(nil)
        end)
        it("rejects inf", function(): ()
            expect(Gate.validate(math.huge, Lync.int(0, 100))).never:toBe(nil)
        end)
    end)

    describe("Gate.validate: float rejects NaN/inf", function(): ()
        it("rejects NaN", function(): ()
            expect(Gate.validate(nan, Lync.float(0, 100, 0.5))).never:toBe(nil)
        end)
        it("rejects inf", function(): ()
            expect(Gate.validate(math.huge, Lync.float(0, 100, 0.5))).never:toBe(nil)
        end)
    end)

    describe("Gate.validate: f32/f64 fallback rejects NaN/inf", function(): ()
        it("f32 NaN", function(): ()
            expect(Gate.validate(nan, Lync.f32)).never:toBe(nil)
        end)
        it("f64 inf", function(): ()
            expect(Gate.validate(math.huge, Lync.f64)).never:toBe(nil)
        end)
    end)
end)

return nil
