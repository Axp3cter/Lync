--!strict
--!optimize 2
-- Bypasses buffer serialization. Uses Roblox remote sidecar refs.

local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Types = require(script.Parent.Parent.Parent.Types)

-- Private ----------------------------------------------------------------

local pushRef = Channel.pushRef
local readu16 = buffer.readu16

local function writeUnknown(ch: Types.ChannelState, value: any): ()
    pushRef(ch, value)
end

local function readUnknown(src: buffer, pos: number, refs: { Instance }?): (any, number)
    if not refs then
        error("[Lync] Unknown.read: refs array is required")
    end
    local idx = readu16(src, pos)
    if idx < 1 or idx > #refs then
        error(`[Lync] Unknown.read: ref index {idx} out of bounds`)
    end
    return refs[idx], 2
end

-- Public -----------------------------------------------------------------

local Unknown = {}

Unknown.unknown = table.freeze({
    _hasUnknown = true,
    write = writeUnknown,
    read = readUnknown,
})

return table.freeze(Unknown)
