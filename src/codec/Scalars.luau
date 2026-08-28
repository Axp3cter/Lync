--!strict
--!optimize 2
-- The scalar constructors, and the parameters each of them will take.

local Base = require ("@src/codec/Base")
local Legality = require ("@src/codec/Legality")
local Log = require ("@src/kernel/Log")
local Types = require ("@src/Types")

local Scalars = {}

-- Constants -----------------------------------------------------------

-- A whole turn, in the degrees every angle is stated in, and the one home of that number.
Scalars.TURN = 360

-- Public --------------------------------------------------------------

-- An angular precision, in the degrees every one of them is spelled in.
function Scalars.precise (kind: string, degrees: number)
    if not (Legality.finite (degrees) and degrees > 0 and degrees <= Scalars.TURN) then
        Log.refuse (`{kind} takes a precision from zero to {Scalars.TURN}, not {degrees}`)
    end
end

--[[
    No value at all, declared where the fact of the call is the whole of what a caller is sending.
    It writes nothing, reads back nothing, and hands a listener nothing rather than a table
    standing in for it.
]]
function Scalars.empty (): Types.Codec<nil> return Base.make ("empty") end

function Scalars.bool (): Types.Codec<boolean> return Base.make ("bool") end

--[[
    Bounds are inclusive, and bounds that meet make a field of no bits carrying one value. How wide
    the range may be is left alone here for the same reason a count is: what a frame holds is a fact
    about the wire, and a refusal at start carries a declaration site this cannot name.
]]
function Scalars.int (min: number, max: number): Types.Codec<number>
    if not (Legality.whole (min) and Legality.whole (max)) then
        Log.refuse (`int takes whole bounds, not {min} to {max}`)
    end
    if min > max then Log.refuse (`int takes its bounds in order, not {min} to {max}`) end

    return Base.make ("int", { min = min, max = max })
end

--[[
    A step need not divide the range. The grid keeps the points it has and the nearest one to the
    top is the last, so a range holding two and a half steps is three points and not four.
]]
function Scalars.quant (min: number, max: number, step: number): Types.Codec<number>
    if not (Legality.finite (min) and Legality.finite (max)) then
        Log.refuse (`quant takes bounds on the line, not {min} to {max}`)
    end
    if min > max then Log.refuse (`quant takes its bounds in order, not {min} to {max}`) end
    if not (Legality.finite (step) and step > 0) then
        Log.refuse (`quant takes a step above zero, not {step}`)
    end

    return Base.make ("quant", { min = min, max = max, step = step })
end

-- One parameter, since the rest of an angle is what an angle is: zero to a turn, and cyclic.
function Scalars.angle (precision: number): Types.Codec<number>
    Scalars.precise ("angle", precision)
    return Base.make ("angle", { step = precision })
end

function Scalars.f32 (): Types.Codec<number> return Base.make ("f32") end

function Scalars.f64 (): Types.Codec<number> return Base.make ("f64") end

function Scalars.vlq (): Types.Codec<number> return Base.make ("vlq") end

function Scalars.vli (): Types.Codec<number> return Base.make ("vli") end

return table.freeze (Scalars)
