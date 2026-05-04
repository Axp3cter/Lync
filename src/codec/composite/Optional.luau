--!strict
--!native
-- Optional codec. 1-byte present/absent flag, value only when present.

local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Log = require(script.Parent.Parent.Parent.util.Log)
local Shared = require(script.Parent.Parent.composite.Shared)
local Types = require(script.Parent.Parent.Parent.Types)

-- Private ----------------------------------------------------------------

local writeByte = Channel.writeByte
local readu8 = buffer.readu8
local bufferLen = buffer.len

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
            Log.assert(pos < bufferLen(src), "presence byte missing at end of buffer")
            if readu8(src, pos) == 0 then
                return nil, 1
            end
            local value, consumed = inner.read(src, pos + 1, refs)
            return value, 1 + consumed
        end,
    }

    -- Propagate _hasUnknown so Gate skips schema validation upstream.
    if inner._hasUnknown then
        codec._hasUnknown = true
    end
    if Shared.containsDelta(inner) then
        codec._hasDelta = true
    end
    return table.freeze(codec)
end

return table.freeze(Optional)
