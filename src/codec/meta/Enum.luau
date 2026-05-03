--!strict
--!native
-- String-keyed enum codec. Maps values to u8 indices at definition time.

local Base = require(script.Parent.Parent.Base)
local Log = require(script.Parent.Parent.Parent.util.Log)
local Types = require(script.Parent.Parent.Parent.Types)

-- Public -----------------------------------------------------------------

local EnumCodec = {}

function EnumCodec.define(...: string): Types.InternalCodec<string>
    local values = { ... }
    local count = #values
    Log.assert(count > 0, "requires at least one variant")
    if count > 256 then
        Log.error(`exceeds 256 variants ({count})`)
    end

    local toIndex: { [string]: number } = {}
    local toValue = table.create(count)
    for i = 1, count do
        local val = values[i]
        if toIndex[val] then
            Log.error(`duplicate value "{val}"`)
        end
        toIndex[val] = i - 1
        toValue[i] = val
    end
    table.freeze(toIndex)
    table.freeze(toValue)

    return Base.define(1, function(b: buffer, off: number, value: string): ()
        local idx = toIndex[value]
        if idx == nil then
            Log.error(`invalid value "{value}"`)
        end
        buffer.writeu8(b, off, idx)
    end, function(b: buffer, off: number): string
        local raw = buffer.readu8(b, off)
        local val = toValue[raw + 1]
        if val == nil then
            Log.error(`invalid index {raw}`)
        end
        return val
    end, { _typeCheck = "string", _isEnum = true, _enumValues = toIndex })
end

return table.freeze(EnumCodec)
