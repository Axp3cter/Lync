--!strict
--!native
-- NumberRange codec. 8B: Min f32 + Max f32.

local Base = require(script.Parent.Parent.Base)
local Log = require(script.Parent.Parent.Parent.util.Log)

-- Private ----------------------------------------------------------------

local writef32 = buffer.writef32
local readf32 = buffer.readf32

local function writeNumberRange(b: buffer, off: number, value: NumberRange): ()
    writef32(b, off, value.Min)
    writef32(b, off + 4, value.Max)
end

--[[
    Reject min > max instead of silently swapping. A swap masks a desync;
    erroring aborts the frame so the transport can reset its baseline.
]]
local function readNumberRange(b: buffer, off: number): NumberRange
    local minV = readf32(b, off)
    local maxV = readf32(b, off + 4)
    if minV > maxV then
        Log.error(`min ({minV}) > max ({maxV})`)
    end
    return NumberRange.new(minV, maxV)
end

-- Public -----------------------------------------------------------------

local NumberRangeCodec = {}

NumberRangeCodec.numberRange = Base.define(8, writeNumberRange, readNumberRange, {
    _typeCheck = "NumberRange",
})

return table.freeze(NumberRangeCodec)
