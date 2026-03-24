--!strict
--!native
-- Variable-length string codec with __call for bounded variant.

local Types  = require(script.Parent.Parent.Parent.Types)
local Base   = require(script.Parent.Parent.Base)
local Varint = require(script.Parent.Parent.primitive.Varint)

-- Private -------------------------------------------------------------

local alloc    = Base.alloc
local writeu8  = buffer.writeu8
local readu8   = buffer.readu8
local INLINE   = Varint.INLINE_MAX

local function writeString(ch: Types.ChannelState, value: string): ()
    local len = #value
    local cursor = ch.cursor

    if len <= INLINE then
        -- Short strings (<= 191 bytes) use a single-byte prefix, avoiding Varint.write overhead
        if cursor + 1 + len > ch.size then alloc(ch, 1 + len) end
        local b = ch.buff
        writeu8(b, cursor, len)
        if len > 0 then
            buffer.writestring(b, cursor + 1, value)
        end
        ch.cursor = cursor + 1 + len
    else
        -- Long strings need multi-byte length encoding
        Varint.write(ch, len)
        cursor = ch.cursor
        if cursor + len > ch.size then alloc(ch, len) end
        buffer.writestring(ch.buff, cursor, value)
        ch.cursor = cursor + len
    end
end

local function readString(
    src: buffer,
    pos: number,
    _refs: { Instance }?
): (string, number)
    local b0 = readu8(src, pos)
    local len: number
    local lenBytes: number

    if b0 <= INLINE then
        len = b0
        lenBytes = 1
    else
        len, lenBytes = Varint.read(src, pos)
    end

    if len == 0 then return "", lenBytes end

    local dataStart = pos + lenBytes
    if dataStart + len > buffer.len(src) then
        error("[Lync] String: length exceeds remaining buffer")
    end

    return buffer.readstring(src, dataStart, len), lenBytes + len
end

-- Bounded variant shares the write function to avoid per-call closure allocation
local function boundedFactory(_self: any, maxLength: number): Types.InternalCodec<string>
    if maxLength <= 0 then
        error("[Lync] Lync.string: maxLength must be positive")
    end

    return table.freeze({
        write = writeString,

        read = function(
            src: buffer,
            pos: number,
            refs: { Instance }?
        ): (string, number)
            local b0 = readu8(src, pos)
            local len: number
            local lenBytes: number

            if b0 <= INLINE then
                len = b0
                lenBytes = 1
            else
                len, lenBytes = Varint.read(src, pos)
            end

            if len > maxLength then
                error(`[Lync] String: length {len} exceeds max {maxLength}`)
            end

            if len == 0 then return "", lenBytes end

            local dataStart = pos + lenBytes
            if dataStart + len > buffer.len(src) then
                error("[Lync] String: length exceeds remaining buffer")
            end

            return buffer.readstring(src, dataStart, len), lenBytes + len
        end,
    } :: any)
end

-- Public --------------------------------------------------------------

local StringCodec = setmetatable({
    write = writeString,
    read = readString,
    _typeCheck = "string",
} :: any, { __call = boundedFactory })

return StringCodec
