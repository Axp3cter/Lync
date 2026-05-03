--!strict
--!optimize 2
-- Optional codec. 1-byte present/absent flag, value only if present.

local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Types = require(script.Parent.Parent.Parent.Types)

-- Private ----------------------------------------------------------------

local writeByte = Channel.writeByte
local readu8 = buffer.readu8

-- Public -----------------------------------------------------------------

local Optional = {}

function Optional.optional(inner: Types.InternalCodec<any>): Types.InternalCodec<any>
    local codec: Types.InternalCodec<any> = {
        _isOptional = true,
        _inner = inner,

        write = function(ch: Types.ChannelState, value: any): ()
            if value == nil then
                writeByte(ch, 0)
                return
            end
            writeByte(ch, 1)
            inner.write(ch, value)
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            if readu8(src, pos) == 0 then
                return nil, 1
            end
            local value, consumed = inner.read(src, pos + 1, refs)
            return value, 1 + consumed
        end,
    }

    if inner._hasUnknown then
        codec._hasUnknown = true
    end
    return table.freeze(codec)
end

local function deepEqual(a: any, b: any): boolean
    if typeof(a) ~= typeof(b) then return false end
    if typeof(a) ~= "table" then return a == b end
    for k, v in a do
        if not deepEqual(v, b[k]) then return false end
    end
    for k in b do
        if a[k] == nil then return false end
    end
    return true
end

function Optional.nullable(inner: Types.InternalCodec<any>, sentinel: any): Types.InternalCodec<any>
    local codec: any = {
        write = function(ch: Types.ChannelState, value: any): ()
            if deepEqual(value, sentinel) then
                writeByte(ch, 0)
                return
            end
            writeByte(ch, 1)
            inner.write(ch, value)
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            if readu8(src, pos) == 0 then
                return sentinel, 1
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
