--!strict
--!native
-- UTF-8 string codec. __call yields a length-bounded variant.

local Base = require(script.Parent.Parent.Base)
local Log = require(script.Parent.Parent.Parent.util.Log)
local Types = require(script.Parent.Parent.Parent.Types)
local Varint = require(script.Parent.Parent.primitive.Varint)

-- Private ----------------------------------------------------------------

local alloc = Base.alloc
local INLINE_MAX = Varint.INLINE_MAX

local function writeString(ch: Types.ChannelState, value: string): ()
    local len = #value
    local cursor = ch.cursor

    -- Single-byte length fast path skips the full varint encode.
    if len <= INLINE_MAX then
        if cursor + 1 + len > ch.size then
            alloc(ch, 1 + len)
        end
        local b = ch.buff
        buffer.writeu8(b, cursor, len)
        if len > 0 then
            buffer.writestring(b, cursor + 1, value)
        end
        ch.cursor = cursor + 1 + len
        return
    end

    Varint.write(ch, len)
    cursor = ch.cursor
    if cursor + len > ch.size then
        alloc(ch, len)
    end
    buffer.writestring(ch.buff, cursor, value)
    ch.cursor = cursor + len
end

local readLengthPrefix = Varint.readLengthPrefix

local function readString(src: buffer, pos: number, _refs: { Instance }?): (string, number)
    local len, lenBytes = readLengthPrefix(src, pos)
    if len == 0 then
        return "", lenBytes
    end

    local dataStart = pos + lenBytes
    if dataStart + len > buffer.len(src) then
        Log.error(`length {len}B exceeds remaining buffer`)
    end
    return buffer.readstring(src, dataStart, len), lenBytes + len
end

-- _maxStringLength lets Gate.validate reject oversized values send-side.
local function boundedFactory(_self, maxLength: number): Types.InternalCodec<string>
    Log.assert(maxLength > 0, "maxLength must be positive")

    return table.freeze({
        _typeCheck = "string",
        _maxStringLength = maxLength,
        write = function(ch: Types.ChannelState, value: string): ()
            if #value > maxLength then
                Log.error(`length {#value} exceeds max {maxLength}`)
            end
            writeString(ch, value)
        end,
        read = function(src: buffer, pos: number, _refs: { Instance }?): (string, number)
            local len, lenBytes = readLengthPrefix(src, pos)
            if len > maxLength then
                Log.error(`length {len} exceeds max {maxLength}`)
            end
            if len == 0 then
                return "", lenBytes
            end

            local dataStart = pos + lenBytes
            if dataStart + len > buffer.len(src) then
                Log.error(`length {len}B exceeds remaining buffer`)
            end
            return buffer.readstring(src, dataStart, len), lenBytes + len
        end,
    })
end

-- Public -----------------------------------------------------------------

return table.freeze(setmetatable({
    _typeCheck = "string",
    write = writeString,
    read = readString,
}, table.freeze({ __call = boundedFactory })))
