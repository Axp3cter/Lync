--!strict
--!optimize 2
-- Optional codec. 1 byte flag, value only if present.

local Base = require(script.Parent.Parent.Base)
local Types = require(script.Parent.Parent.Parent.Types)

-- Private -------------------------------------------------------------

local alloc = Base.alloc
local writeu8 = buffer.writeu8
local readu8 = buffer.readu8

-- Public --------------------------------------------------------------

local Optional = {}

function Optional.optional(inner: Types.InternalCodec<any>): Types.InternalCodec<any>
    local codec: any = {
        write = function(ch: Types.ChannelState, value: any): ()
            local cursor = ch.cursor
            if cursor + 1 > ch.size then
                alloc(ch, 1)
            end
            if value == nil then
                writeu8(ch.buff, cursor, 0)
                ch.cursor = cursor + 1
            else
                writeu8(ch.buff, cursor, 1)
                ch.cursor = cursor + 1
                inner.write(ch, value)
            end
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            local flag = readu8(src, pos)
            if flag == 0 then
                return nil, 1
            end
            local value, consumed = inner.read(src, pos + 1, refs)
            return value, 1 + consumed
        end,
    }

    if (inner :: any)._hasUnknown then
        codec._hasUnknown = true
    end

    return table.freeze(codec)
end

return table.freeze(Optional)
