--!strict
--!optimize 2
-- The scalar constructors: what each records, and the parameters each turns away.

local Base = require("@src/codec/Base")
local Scalars = require("@src/codec/Scalars")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local LOW = 0
local HIGH = 10
local STEP = 0.5
local TURN = Scalars.TURN
local FINE = 1

local NOWHERE = table.freeze({ 0 / 0, 1 / 0, -1 / 0 })

local function params(of: any): Base.Params
    return Base.cell(of).params
end

return {
    Harness.case("scalars.plain-kinds", function()
        for kind, make in
            {
                empty = Scalars.empty,
                bool = Scalars.bool,
                f32 = Scalars.f32,
                f64 = Scalars.f64,
                vlq = Scalars.vlq,
                vli = Scalars.vli,
            } :: { [string]: () -> any }
        do
            local of = make()
            Expect.equal(Base.cell(of).kind, kind)
            Expect.equal(next(params(of) :: any), nil)
        end
    end),

    -- Bounds are inclusive and may meet.
    Harness.case("scalars.int", function()
        local of = Scalars.int(LOW, HIGH)
        Expect.equal(Base.cell(of).kind, "int")
        Expect.equal(params(of).min, LOW)
        Expect.equal(params(of).max, HIGH)
        Expect.equal(params(Scalars.int(HIGH, HIGH)).min, HIGH)
        Expect.equal(params(Scalars.int(-HIGH, HIGH)).min, -HIGH)

        Expect.throws(function()
            Scalars.int(HIGH, LOW)
        end, "in order")
        Expect.throws(function()
            Scalars.int(LOW, STEP)
        end, "whole bounds")
        for _, value in NOWHERE do
            Expect.throws(function()
                Scalars.int(LOW, value)
            end, "whole bounds")
        end
    end),

    Harness.case("scalars.quant", function()
        local of = Scalars.quant(-HIGH, HIGH, STEP)
        Expect.equal(Base.cell(of).kind, "quant")
        Expect.equal(params(of).min, -HIGH)
        Expect.equal(params(of).max, HIGH)
        Expect.equal(params(of).step, STEP)
        Scalars.quant(STEP, STEP, STEP)

        Expect.throws(function()
            Scalars.quant(HIGH, LOW, STEP)
        end, "in order")
        Expect.throws(function()
            Scalars.quant(LOW, HIGH, 0)
        end, "a step above zero")
        Expect.throws(function()
            Scalars.quant(LOW, HIGH, -STEP)
        end, "a step above zero")
        for _, value in NOWHERE do
            Expect.throws(function()
                Scalars.quant(LOW, value, STEP)
            end, "on the line")
            Expect.throws(function()
                Scalars.quant(LOW, HIGH, value)
            end, "a step above zero")
        end
    end),

    -- The precision range is open at the bottom and closed at the top: a whole turn is one point.
    Harness.case("scalars.angle-precision-ends", function()
        Expect.equal(params(Scalars.angle(TURN)).step, TURN)
        Expect.equal(params(Scalars.angle(FINE)).step, FINE)

        local turns = "takes a precision above zero"
        for _, bad in { 0, -FINE, TURN + FINE, 0 / 0, 1 / 0 } do
            Expect.throws(function()
                Scalars.angle(bad)
            end, turns)
            Expect.throws(function()
                Scalars.precise("elsewhere", bad)
            end, "elsewhere")
        end
    end),
}
