--!strict
--!optimize 2
-- Boolean codec with bitpacking flag for struct and array codecs.

local Base = require(script.Parent.Parent.Base)

-- Public --------------------------------------------------------------

local Bool = {}

Bool.bool = Base.define(1, function(b: buffer, off: number, value: boolean): ()
    buffer.writeu8(b, off, if value then 1 else 0)
end, function(b: buffer, off: number): boolean
    return buffer.readu8(b, off) ~= 0
end, {
    _isBool = true,
    _typeCheck = "boolean",
})

return table.freeze(Bool)
