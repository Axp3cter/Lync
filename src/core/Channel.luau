--!strict
--!native
-- Channel.luau — Isolated per-channel buffer state with adaptive shrinking.

local Types = require(script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Constants --------------------------------------------------------------

local INITIAL_SIZE  = 256
local MAX_SIZE      = 65536
local GROWTH        = 2
local SHRINK_FRAMES = 60
local SHRINK_RATIO  = 0.25

local max = math.max

-- Public -----------------------------------------------------------------

local Channel = {}

function Channel.create(): ChannelState
    return {
        buff      = buffer.create(INITIAL_SIZE),
        cursor    = 0,
        size      = INITIAL_SIZE,
        refs      = {},
        lowFrames = 0,
    }
end

function Channel.alloc(ch: ChannelState, bytes: number): ()
    local needed = ch.cursor + bytes
    if needed <= ch.size then return end
    if needed > MAX_SIZE then error(`[Lync] Buffer overflow: {needed} bytes exceeds {MAX_SIZE} limit`) end

    local newSize = ch.size
    while needed > newSize do
        newSize *= GROWTH
    end

    local newBuff = buffer.create(newSize)
    buffer.copy(newBuff, 0, ch.buff, 0, ch.cursor)
    ch.buff = newBuff
    ch.size = newSize
end

function Channel.dump(ch: ChannelState): (buffer, { Instance }?)
    local cur = ch.cursor
    local out = buffer.create(cur)
    buffer.copy(out, 0, ch.buff, 0, cur)

    local refs = ch.refs
    if #refs == 0 then return out, nil end

    return out, table.clone(refs)
end

function Channel.reset(ch: ChannelState): ()
    local usage = ch.cursor
    local size  = ch.size

    ch.cursor = 0
    table.clear(ch.refs)

    if usage < size * SHRINK_RATIO then
        ch.lowFrames += 1
        if ch.lowFrames >= SHRINK_FRAMES and size > INITIAL_SIZE then
            local half   = max(INITIAL_SIZE, size // GROWTH)
            ch.buff      = buffer.create(half)
            ch.size      = half
            ch.lowFrames = 0
        end
    else
        ch.lowFrames = 0
    end
end

return table.freeze(Channel)
