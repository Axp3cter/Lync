--!strict
--!native
-- User-defined fixed-size codec factory.

local Channel = require (script.Parent.Parent.core.Channel)
local alloc = Channel.alloc
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T> = Types.Codec<T>

-- Constants --------------------------------------------------------------

local floor = math.floor

-- Public -----------------------------------------------------------------

local Custom = {}

function Custom.define <T>(
    size: number,
    writeFn: (b: buffer, offset: number, value: T) -> (),
    readFn: (b: buffer, offset: number) -> T
): Codec<T>
    if size < 0 or size ~= floor (size) then
        error (`[Lync] Custom codec size must be a non-negative integer, got {size}`)
    end

    if size == 0 then
        return table.freeze ({
            _size = 0,
            _directWrite = function (_b: buffer, _offset: number, _value: T): () end,
            _directRead = function (_b: buffer, _offset: number): T
                return nil :: any
            end,
            write = function (_ch: ChannelState, _value: T): () end,
            read = function (_src: buffer, _pos: number, _refs: { Instance }?): (T, number)
                return nil :: any, 0
            end,
        })
    end

    return table.freeze ({
        _size = size,
        _directWrite = writeFn,
        _directRead = readFn,
        write = function (ch: ChannelState, value: T): ()
            local c = ch.cursor
            if c + size > ch.size then
                alloc (ch, size)
            end
            writeFn (ch.buff, c, value)
            ch.cursor = c + size
        end,
        read = function (src: buffer, pos: number, _refs: { Instance }?): (T, number)
            return readFn (src, pos), size
        end,
    })
end

return table.freeze (Custom)
