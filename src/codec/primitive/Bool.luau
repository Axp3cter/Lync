--!strict
--!optimize 2
-- 1-byte boolean codec. _isBool flag opts struct/array into bit packing.

local Base = require(script.Parent.Parent.Base)

-- Private ----------------------------------------------------------------

local function writeBool(b: buffer, off: number, value: boolean): ()
    buffer.writeu8(b, off, if value then 1 else 0)
end

local function readBool(b: buffer, off: number): boolean
    return buffer.readu8(b, off) ~= 0
end

-- Public -----------------------------------------------------------------

local Bool = {}

Bool.bool = Base.define(1, writeBool, readBool, {
    _isBool = true,
    _typeCheck = "boolean",
})

return table.freeze(Bool)
