--!strict
--!optimize 2
-- String-keyed enum codec. Maps values to u8 indices at definition time.

local Base = require(script.Parent.Parent.Base)
local Types = require(script.Parent.Parent.Parent.Types)

-- Public -----------------------------------------------------------------

local EnumCodec = {}

function EnumCodec.define(...: string): Types.InternalCodec<string>
    local values = { ... }
    local count = #values
    if count == 0 then
        error("[Lync] Lync.enum: requires at least one value")
    end
    if count > 256 then
        error("[Lync] Lync.enum: exceeds 256 variants")
    end

    local toIndex: { [string]: number } = {}
    local toValue = table.create(count)
    for i = 1, count do
        local val = values[i]
        if toIndex[val] then
            error(`[Lync] Lync.enum: duplicate value "{val}"`)
        end
        toIndex[val] = i - 1
        toValue[i] = val
    end
    table.freeze(toIndex)
    table.freeze(toValue)

    return Base.define(1, function(b: buffer, off: number, value: string): ()
        local idx = toIndex[value]
        if idx == nil then
            error(`[Lync] Enum.write: invalid value "{value}"`)
        end
        buffer.writeu8(b, off, idx)
    end, function(b: buffer, off: number): string
        local val = toValue[buffer.readu8(b, off) + 1]
        if val == nil then
            error(`[Lync] Enum.read: invalid index`)
        end
        return val
    end, { _typeCheck = "string", _isEnum = true, _enumValues = toIndex })
end

return table.freeze(EnumCodec)
