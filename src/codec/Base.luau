--!strict
--!native
-- Fixed-size codec factory. Every fixed-size codec calls Base.define once.
-- Generates write (alloc + cursor bump) and read (return + size) automatically.

local Channel = require (script.Parent.Parent.internal.Channel)
local alloc = Channel.alloc

-- Public -----------------------------------------------------------------

local Base = {}

function Base.define <T>(
    size: number,
    directWrite: (b: buffer, offset: number, value: T) -> (),
    directRead: (b: buffer, offset: number) -> T
): any
    return table.freeze ({
        _size = size,
        _directWrite = directWrite,
        _directRead = directRead,
        write = function (ch: any, value: T): ()
            local c = ch.cursor
            if c + size > ch.size then
                alloc (ch, size)
            end
            directWrite (ch.buff, c, value)
            ch.cursor = c + size
        end,
        read = function (src: buffer, pos: number, _refs: { Instance }?): (T, number)
            return directRead (src, pos), size
        end,
    })
end

function Base.zero (): any
    return table.freeze ({
        _size = 0,
        _directWrite = function (_b: buffer, _offset: number, _value: any): () end,
        _directRead = function (_b: buffer, _offset: number): any
            return nil
        end,
        write = function (_ch: any, _value: any): () end,
        read = function (_src: buffer, _pos: number, _refs: { Instance }?): (any, number)
            return nil, 0
        end,
    })
end

return table.freeze (Base)
