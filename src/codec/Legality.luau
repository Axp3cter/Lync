--!strict
--!optimize 2
-- What a constructor will take: the tests every one of them makes of a parameter or a child.

local Base = require ("@src/codec/Base")
local Log = require ("@src/kernel/Log")
local Types = require ("@src/Types")

local Legality = {}

-- Public --------------------------------------------------------------

--[[
    The annotation is erased at run time, so a numeric string would be coerced downstream and
    recorded as a parameter. A NaN fails both comparisons, and that is the whole test.
]]
function Legality.finite (value: number): boolean
    return type (value) == "number" and value > -math.huge and value < math.huge
end

-- Whole and finite at once: an infinity or a NaN leaves a NaN behind in the modulo.
function Legality.whole (value: number): boolean
    if type (value) ~= "number" then return false end
    return value % 1 == 0
end

--[[
    The count range every counted kind takes, and none of them takes differently. Zero is legal at
    either end, so an empty string and an empty list are both declarable, and bounds that meet
    declare a count of no bits at all.
]]
function Legality.counts (kind: string, min: number, max: number)
    if not (Legality.whole (min) and Legality.whole (max)) then
        Log.refuse (`{kind} takes whole bounds, not {min} to {max}`)
    end
    if min < 0 then Log.refuse (`{kind} takes bounds from zero up, not {min}`) end
    if min > max then Log.refuse (`{kind} takes its bounds in order, not {min} to {max}`) end
end

--[[
    A child, refused where it is anything else. Every composite takes one, and the mistake a caller
    makes is handing over the value they meant to describe instead, so the refusal names what
    arrived as well as where it was wanted.
]]
function Legality.codec (kind: string, at: string, of: Types.Codec<any>)
    if not Base.made (of) then Log.refuse (`{kind} takes a codec for {at}, not a {typeof (of)}`) end

    --[[
        Nothing is a whole payload and never a part of one. A slot carrying no value need not have
        been declared, and the read would be handed nothing to put under a name that is waiting
        for something.
    ]]
    if Base.cell (of).kind == "empty" then
        Log.refuse (`{kind} takes no empty for {at}, which carries nothing to be a part of`)
    end
end

--[[
    A child, and the one place an optional may not be. Two slots cannot tell an absent value from an
    absent slot: a list element and a map entry are read back by their presence, so an optional
    there decodes as a hole, and an optional inside an optional is one absence written twice.
]]
function Legality.bare (kind: string, at: string, of: Types.Codec<any>)
    Legality.codec (kind, at, of)
    if Base.cell (of).kind == "optional" then
        Log.refuse (`{kind} takes no optional for {at}, since an absent slot is already absent`)
    end
end

return table.freeze (Legality)
