--!strict
--!optimize 2
-- The ranged-int bit width: the bits needed to address a span of values.

local Bits = {}

--[[
    A logarithm rounds short from two to the forty-ninth up, and a width a bit short encodes cleanly
    and decodes as a different value.
]]
function Bits.width (span: number): number
    if span <= 0 then return 0 end
    return (select (2, math.frexp (span)))
end

return table.freeze (Bits)
