--!strict
--!optimize 2
-- Bypasses buffer serialization. Uses Roblox remote sidecar refs.

local Types = require(script.Parent.Parent.Parent.Types)
local Base  = require(script.Parent.Parent.Base)

-- Private -------------------------------------------------------------

local alloc    = Base.alloc
local writeu16 = buffer.writeu16
local readu16  = buffer.readu16

-- Public --------------------------------------------------------------

local Unknown = {}

Unknown.unknown = table.freeze({
    _hasUnknown = true,

    write = function(ch: Types.ChannelState, value: any): ()
        local idx = ch.refCount + 1
        if idx > 0xFFFF then
            error("[Lync] Unknown: ref overflow (>65535)")
        end

        ch.refs[idx] = value :: any
        ch.refCount = idx

        local cursor = ch.cursor
        if cursor + 2 > ch.size then alloc(ch, 2) end
        writeu16(ch.buff, cursor, idx)
        ch.cursor = cursor + 2
    end,

    read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
        if not refs then
            error("[Lync] Unknown: read requires refs array")
        end

        local idx = readu16(src, pos)
        return (refs :: any)[idx], 2
    end,
} :: any)

return table.freeze(Unknown)
