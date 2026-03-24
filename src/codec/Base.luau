--!strict
--!optimize 2
-- Fixed-size codec factory with buffer allocation.

local Types = require(script.Parent.Parent.Types)

-- Constants -----------------------------------------------------------

local DEFAULT_MAX = 262144

-- State ---------------------------------------------------------------

local _maxSize = DEFAULT_MAX

-- Private -------------------------------------------------------------

local countlz = bit32.countlz
local lshift  = bit32.lshift

local function alloc(ch: Types.ChannelState, bytes: number): ()
    local needed = ch.cursor + bytes
    if needed <= ch.size then return end

    if needed > _maxSize then
        local name = ch.currentPacket
        error(
            if name
                then `[Lync] Channel: buffer overflow ({needed}B, max {_maxSize}B) in "{name}"`
                else `[Lync] Channel: buffer overflow ({needed}B, max {_maxSize}B)`
        )
    end

    local newSize = lshift(1, 32 - countlz(needed - 1))
    local newBuff = buffer.create(newSize)
    buffer.copy(newBuff, 0, ch.buff, 0, ch.cursor)
    ch.buff = newBuff
    ch.size = newSize
end

-- Public --------------------------------------------------------------

local Base = {}

function Base.alloc(ch: Types.ChannelState, bytes: number): ()
    alloc(ch, bytes)
end

function Base.setMaxSize(bytes: number): ()
    _maxSize = bytes
end

function Base.define<T>(
    size: number,
    directWrite: (b: buffer, offset: number, value: T) -> (),
    directRead: (b: buffer, offset: number) -> T,
    meta: { [string]: any }?
): Types.InternalCodec<T>
    local codec: any = {
        _size = size,
        _directWrite = directWrite,
        _directRead = directRead,

        write = function(ch: Types.ChannelState, value: T): ()
            local cursor = ch.cursor
            if cursor + size > ch.size then alloc(ch, size) end
            directWrite(ch.buff, cursor, value)
            ch.cursor = cursor + size
        end,

        read = function(src: buffer, pos: number, _refs: { Instance }?): (T, number)
            return directRead(src, pos), size
        end,
    }

    if meta then
        for key, val in meta do
            codec[key] = val
        end
    end

    return table.freeze(codec)
end

function Base.zero(): Types.InternalCodec<nil>
    return table.freeze({
        _size = 0,
        _directWrite = function(_b: buffer, _off: number, _v: nil): () end,
        _directRead = function(_b: buffer, _off: number): nil
            return nil
        end,
        write = function(_ch: Types.ChannelState, _v: nil): () end,
        read = function(_src: buffer, _pos: number, _refs: { Instance }?): (nil, number)
            return nil, 0
        end,
    } :: any)
end

return table.freeze(Base)
