--!strict
--!native
-- Boolean codec. _isBool tells struct to pack into bitfields.

local Channel = require (script.Parent.Parent.Parent.internal.Channel)
local alloc = Channel.alloc

return table.freeze ({
    bool = table.freeze ({
        _size = 1,
        _isBool = true,
        _directWrite = function (b: buffer, offset: number, value: boolean): ()
            buffer.writeu8 (b, offset, if value then 1 else 0)
        end,
        _directRead = function (b: buffer, offset: number): boolean
            return buffer.readu8 (b, offset) ~= 0
        end,
        write = function (ch: any, value: boolean): ()
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
    }),
})
