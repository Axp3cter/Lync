--!strict
--!native
-- Per-channel buffer state with batching, delta cache, frame XOR.

local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Constants --------------------------------------------------------------

local INITIAL_SIZE = 1024
local MAX_SIZE = 65536
local MAX_BATCH = 65535

local min = math.min
local bxor = bit32.bxor
local floor = math.floor
local countlz = bit32.countlz
local lshift = bit32.lshift

-- Public -----------------------------------------------------------------

local Channel = {}

function Channel.create (): ChannelState
    return {
        buff = buffer.create (INITIAL_SIZE),
        cursor = 0,
        size = INITIAL_SIZE,
        refs = {},
        lastId = -1,
        countPos = 0,
        batchCount = 0,
        deltas = {},
        prevDump = nil,
    }
end

function Channel.alloc (ch: ChannelState, bytes: number): ()
    local needed = ch.cursor + bytes
    if needed <= ch.size then
        return
    end
    if needed > MAX_SIZE then
        error (`[Lync] Channel buffer overflow: {needed} > {MAX_SIZE}`)
    end

    local newSize = lshift (1, 32 - countlz (needed - 1))

    local newBuff = buffer.create (newSize)
    buffer.copy (newBuff, 0, ch.buff, 0, ch.cursor)
    ch.buff = newBuff
    ch.size = newSize
end

function Channel.sealAndDump (ch: ChannelState): (buffer, { Instance }?)
    if ch.lastId >= 0 then
        buffer.writeu16 (ch.buff, ch.countPos, ch.batchCount)
        ch.lastId = -1
        ch.countPos = 0
        ch.batchCount = 0
    end

    local cur = ch.cursor
    local out = buffer.create (cur)
    buffer.copy (out, 0, ch.buff, 0, cur)

    local refs = ch.refs
    return out, if #refs > 0 then table.clone (refs) else nil
end

local function openBatch (ch: ChannelState, id: number): ()
    if id ~= ch.lastId or ch.batchCount >= MAX_BATCH then
        if ch.lastId >= 0 then
            buffer.writeu16 (ch.buff, ch.countPos, ch.batchCount)
        end

        Channel.alloc (ch, 3)
        local c = ch.cursor
        buffer.writeu8 (ch.buff, c, id)
        ch.countPos = c + 1
        ch.cursor = c + 3
        ch.lastId = id
        ch.batchCount = 0
    end

    ch.batchCount += 1
end

function Channel.writeBatch (ch: ChannelState, id: number, codec: any, data: any): ()
    openBatch (ch, id)
    codec.write (ch, data)
end

--[[
    Append pre-serialized bytes into a batch. Assumes src was produced by a
    single codec.write call into a scratch channel. refs are appended as-is.
]]
function Channel.writeBatchRaw (
    ch: ChannelState,
    id: number,
    src: buffer,
    srcLen: number,
    srcRefs: { Instance }?
): ()
    openBatch (ch, id)

    if srcLen > 0 then
        Channel.alloc (ch, srcLen)
        buffer.copy (ch.buff, ch.cursor, src, 0, srcLen)
        ch.cursor += srcLen
    end

    if srcRefs then
        local refs = ch.refs
        table.move (srcRefs, 1, #srcRefs, #refs + 1, refs)
    end
end

local function sealOpen (ch: ChannelState): ()
    if ch.lastId >= 0 then
        buffer.writeu16 (ch.buff, ch.countPos, ch.batchCount)
        ch.lastId = -1
        ch.countPos = 0
        ch.batchCount = 0
    end
end

--[[
    Write a query frame. Seals any open batch, writes id + correlationId +
    status header. If codec is provided, writes status 0 + payload.
    If codec is nil, writes status 1 (nil response, no payload).
]]
function Channel.writeQuery (
    ch: ChannelState,
    id: number,
    correlationId: number,
    codec: any?,
    data: any?
): ()
    sealOpen (ch)

    Channel.alloc (ch, 3)
    local c = ch.cursor
    buffer.writeu8 (ch.buff, c, id)
    buffer.writeu8 (ch.buff, c + 1, correlationId)

    if codec then
        buffer.writeu8 (ch.buff, c + 2, 0)
        ch.cursor = c + 3
        codec.write (ch, data)
    else
        buffer.writeu8 (ch.buff, c + 2, 1)
        ch.cursor = c + 3
    end
end

--[[
    XOR a buffer against a previous buffer. Overlapping region is XOR'd,
    remaining bytes (if current is longer) are copied raw. Produces a buffer
    with many zero bytes when frame-to-frame content is similar.
]]
function Channel.xorApply (current: buffer, previous: buffer?): buffer
    local curLen = buffer.len (current)
    if not previous then
        return current
    end

    local prevLen = buffer.len (previous :: buffer)
    if prevLen == 0 then
        return current
    end

    local result = buffer.create (curLen)
    local overlap = min (curLen, prevLen)
    local prev = previous :: buffer

    -- u32 fast path for aligned portion
    local aligned = floor (overlap / 4) * 4
    for i = 0, aligned - 4, 4 do
        buffer.writeu32 (result, i, bxor (buffer.readu32 (current, i), buffer.readu32 (prev, i)))
    end

    -- Remaining bytes
    for i = aligned, overlap - 1 do
        buffer.writeu8 (result, i, bxor (buffer.readu8 (current, i), buffer.readu8 (prev, i)))
    end

    if curLen > overlap then
        buffer.copy (result, overlap, current, overlap, curLen - overlap)
    end

    return result
end

function Channel.reset (ch: ChannelState): ()
    ch.cursor = 0
    ch.lastId = -1
    ch.countPos = 0
    ch.batchCount = 0
    table.clear (ch.refs)
end

return table.freeze (Channel)
