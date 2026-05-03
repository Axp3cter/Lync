--!strict
--!optimize 2
-- IEEE 754 binary16 codec.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.primitive.Float16", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("metadata", function(): ()
        it("_size = 2", function(): ()
            expect((Lync.f16 :: any)._size):toBe(2)
        end)
        it("_typeCheck = number", function(): ()
            expect((Lync.f16 :: any)._typeCheck):toBe("number")
        end)
    end)

    describe("exact representations", function(): ()
        it("0", function(): ()
            expect(Channel.roundTripStrict(Lync.f16, 0)):toBe(0)
        end)
        it("1", function(): ()
            expect(Channel.roundTripStrict(Lync.f16, 1)):toBe(1)
        end)
        it("-1", function(): ()
            expect(Channel.roundTripStrict(Lync.f16, -1)):toBe(-1)
        end)
        it("0.5", function(): ()
            expect(Channel.roundTripStrict(Lync.f16, 0.5)):toBe(0.5)
        end)
        it("max finite 65504", function(): ()
            expect(Channel.roundTripStrict(Lync.f16, 65504)):toBe(65504)
        end)
        it("-65504", function(): ()
            expect(Channel.roundTripStrict(Lync.f16, -65504)):toBe(-65504)
        end)
    end)

    describe("approximate representations", function(): ()
        it("0.1 within 0.001", function(): ()
            expect(Channel.roundTripStrict(Lync.f16, 0.1)):toBeCloseTo(0.1, 1e-3)
        end)
        it("100.5 within 0.1", function(): ()
            expect(Channel.roundTripStrict(Lync.f16, 100.5)):toBeCloseTo(100.5, 0.1)
        end)
        it("-42.25 within 0.1", function(): ()
            expect(Channel.roundTripStrict(Lync.f16, -42.25)):toBeCloseTo(-42.25, 0.1)
        end)
    end)

    describe("subnormal and overflow handling", function(): ()
        it("subnormal positive round-trips approximately", function(): ()
            expect(Channel.roundTripStrict(Lync.f16, 6e-5)):toBeCloseTo(6e-5, 2e-5)
        end)
        it("subnormal negative round-trips approximately", function(): ()
            expect(Channel.roundTripStrict(Lync.f16, -6e-5)):toBeCloseTo(-6e-5, 2e-5)
        end)
        it("positive overflow saturates to +inf", function(): ()
            expect(Channel.roundTripStrict(Lync.f16, 100000)):toBe(math.huge)
        end)
        it("negative overflow saturates to -inf", function(): ()
            expect(Channel.roundTripStrict(Lync.f16, -100000)):toBe(-math.huge)
        end)
        it("NaN preserved", function(): ()
            expect(Channel.roundTripStrict(Lync.f16, 0 / 0)):toBeNaN()
        end)
    end)

    describe("wire format", function(): ()
        it("0 encodes to 0x00 0x00", function(): ()
            local r = Channel.encode(Lync.f16, 0)
            expect(r.buffer):toMatchBuffer({ 0x00, 0x00 })
        end)
        it("uses exactly 2 bytes regardless of value", function(): ()
            local _, w1 = Channel.roundTripStrict(Lync.f16, 0)
            local _, w2 = Channel.roundTripStrict(Lync.f16, 65504)
            local _, w3 = Channel.roundTripStrict(Lync.f16, math.huge)
            expect(w1):toBe(2)
            expect(w2):toBe(2)
            expect(w3):toBe(2)
        end)
    end)
end)

return nil
