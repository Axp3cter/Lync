--!strict
--!optimize 2
-- util.Constants: integer limits and frame-header bit layout.

local Env = require(script:FindFirstAncestor("test").Env)

local Sandbox = Env.Sandbox

local Constants = require(script:FindFirstAncestor("Lync").util.Constants)

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("util.Constants", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("unsigned integer limits", function(): ()
        it("U8_MAX = 255", function(): ()
            expect(Constants.U8_MAX):toBe(0xFF)
        end)
        it("U16_MAX = 65535", function(): ()
            expect(Constants.U16_MAX):toBe(0xFFFF)
        end)
        it("U32_MAX = 4294967295", function(): ()
            expect(Constants.U32_MAX):toBe(0xFFFFFFFF)
        end)
        it("each width is one byte wider than the previous", function(): ()
            expect(Constants.U16_MAX > Constants.U8_MAX):toBe(true)
            expect(Constants.U32_MAX > Constants.U16_MAX):toBe(true)
        end)
    end)

    describe("signed integer limits (two's complement)", function(): ()
        it("I8_MIN = -128, I8_MAX = 127", function(): ()
            expect(Constants.I8_MIN):toBe(-0x80)
            expect(Constants.I8_MAX):toBe(0x7F)
        end)
        it("I16_MIN = -32768, I16_MAX = 32767", function(): ()
            expect(Constants.I16_MIN):toBe(-0x8000)
            expect(Constants.I16_MAX):toBe(0x7FFF)
        end)
        it("I32_MIN = -2^31, I32_MAX = 2^31 - 1", function(): ()
            expect(Constants.I32_MIN):toBe(-0x80000000)
            expect(Constants.I32_MAX):toBe(0x7FFFFFFF)
        end)
        it("|I8_MIN| = I8_MAX + 1 (asymmetric range)", function(): ()
            expect(-Constants.I8_MIN):toBe(Constants.I8_MAX + 1)
        end)
        it("|I16_MIN| = I16_MAX + 1", function(): ()
            expect(-Constants.I16_MIN):toBe(Constants.I16_MAX + 1)
        end)
        it("|I32_MIN| = I32_MAX + 1", function(): ()
            expect(-Constants.I32_MIN):toBe(Constants.I32_MAX + 1)
        end)
    end)

    describe("frame header bit layout", function(): ()
        it("FRAME_MSB = 0x80 (high bit of a byte)", function(): ()
            expect(Constants.FRAME_MSB):toBe(0x80)
        end)
        it("FRAME_ID_MASK = 0x7F (low 7 bits)", function(): ()
            expect(Constants.FRAME_ID_MASK):toBe(0x7F)
        end)
        it("MSB and ID mask cover every bit of a byte (no overlap, no gap)", function(): ()
            expect(bit32.bor(Constants.FRAME_MSB, Constants.FRAME_ID_MASK)):toBe(0xFF)
            expect(bit32.band(Constants.FRAME_MSB, Constants.FRAME_ID_MASK)):toBe(0)
        end)
        it("ID mask permits at most 128 distinct ids (caps the registry)", function(): ()
            expect(Constants.FRAME_ID_MASK + 1):toBe(128)
        end)
    end)

    describe("batch limits", function(): ()
        it("MAX_BATCH_ITEMS = U16_MAX (count is a u16)", function(): ()
            expect(Constants.MAX_BATCH_ITEMS):toBe(Constants.U16_MAX)
        end)
    end)

    describe("module shape", function(): ()
        it("Constants is frozen", function(): ()
            expect(Constants):toBeFrozen()
        end)
    end)
end)

return nil
