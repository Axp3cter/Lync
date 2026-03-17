--!strict
--!native
-- u8, u16, u32, i8, i16, i32, f32, f64 codecs.

local Base = require (script.Parent.Parent.Base)

return table.freeze ({
    u8 = Base.define (1, function (b: buffer, o: number, v: number): ()
        buffer.writeu8 (b, o, v)
    end, function (b: buffer, o: number): number
        return buffer.readu8 (b, o)
    end),
    u16 = Base.define (2, function (b: buffer, o: number, v: number): ()
        buffer.writeu16 (b, o, v)
    end, function (b: buffer, o: number): number
        return buffer.readu16 (b, o)
    end),
    u32 = Base.define (4, function (b: buffer, o: number, v: number): ()
        buffer.writeu32 (b, o, v)
    end, function (b: buffer, o: number): number
        return buffer.readu32 (b, o)
    end),
    i8 = Base.define (1, function (b: buffer, o: number, v: number): ()
        buffer.writei8 (b, o, v)
    end, function (b: buffer, o: number): number
        return buffer.readi8 (b, o)
    end),
    i16 = Base.define (2, function (b: buffer, o: number, v: number): ()
        buffer.writei16 (b, o, v)
    end, function (b: buffer, o: number): number
        return buffer.readi16 (b, o)
    end),
    i32 = Base.define (4, function (b: buffer, o: number, v: number): ()
        buffer.writei32 (b, o, v)
    end, function (b: buffer, o: number): number
        return buffer.readi32 (b, o)
    end),
    f32 = Base.define (4, function (b: buffer, o: number, v: number): ()
        buffer.writef32 (b, o, v)
    end, function (b: buffer, o: number): number
        return buffer.readf32 (b, o)
    end),
    f64 = Base.define (8, function (b: buffer, o: number, v: number): ()
        buffer.writef64 (b, o, v)
    end, function (b: buffer, o: number): number
        return buffer.readf64 (b, o)
    end),
})
