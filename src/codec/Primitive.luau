--!strict
--!native
-- Fixed-size numeric and boolean codecs via factory.

local Channel = require (script.Parent.Parent.core.Channel)
local alloc = Channel.alloc
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T> = Types.Codec<T>

-- Private ----------------------------------------------------------------

local function numeric (
    writeFn: (b: buffer, offset: number, v: number) -> (),
    readFn: (b: buffer, offset: number) -> number,
    bytes: number
): Codec<number>
    return table.freeze ({
        _size = bytes,
        _directWrite = writeFn,
        _directRead = readFn,
        write = function (ch: ChannelState, value: number): ()
            local c = ch.cursor
            if c + bytes > ch.size then
                alloc (ch, bytes)
            end
            writeFn (ch.buff, c, value)
            ch.cursor = c + bytes
        end,
        read = function (src: buffer, pos: number, _refs: { Instance }?): (number, number)
            return readFn (src, pos), bytes
        end,
    })
end

-- Public -----------------------------------------------------------------

local Primitive = {
    u8 = numeric (buffer.writeu8, buffer.readu8, 1),
    u16 = numeric (buffer.writeu16, buffer.readu16, 2),
    u32 = numeric (buffer.writeu32, buffer.readu32, 4),
    i8 = numeric (buffer.writei8, buffer.readi8, 1),
    i16 = numeric (buffer.writei16, buffer.readi16, 2),
    i32 = numeric (buffer.writei32, buffer.readi32, 4),
    f32 = numeric (buffer.writef32, buffer.readf32, 4),
    f64 = numeric (buffer.writef64, buffer.readf64, 8),

    --[[
        _isBool sentinel: Composite.struct reads this to pack boolean fields
        into bitfields instead of writing them as full bytes. Any custom codec
        that sets _isBool = true MUST serialize exactly like this.
    ]]
    bool = table.freeze ({
        _size = 1,
        _isBool = true,
        _directWrite = function (b: buffer, offset: number, value: boolean): ()
            buffer.writeu8 (b, offset, if value then 1 else 0)
        end,
        _directRead = function (b: buffer, offset: number): boolean
            return buffer.readu8 (b, offset) ~= 0
        end,
        write = function (ch: ChannelState, value: boolean): ()
            local c = ch.cursor
            if c + 1 > ch.size then
                alloc (ch, 1)
            end
            buffer.writeu8 (ch.buff, c, if value then 1 else 0)
            ch.cursor = c + 1
        end,
        read = function (src: buffer, pos: number, _refs: { Instance }?): (boolean, number)
            return buffer.readu8 (src, pos) ~= 0, 1
        end,
    }) :: Codec<boolean>,
}

return table.freeze (Primitive)
