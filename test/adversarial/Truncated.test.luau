--!strict
--!optimize 2
local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)
local Varint = require (script.Parent.Parent.Parent.codec.primitive.Varint)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe ("varint truncation", function (): ()
    it ("throws on continuation byte at EOF", function (): ()
        expect (function (): ()
            local buf = buffer.create (1)
            buffer.writeu8 (buf, 0, 0x80)
            Varint.read (buf, 0)
        end):toThrow ()
    end)
end)

describe ("string truncation", function (): ()
    it ("throws when length exceeds buffer", function (): ()
        expect (function (): ()
            local buf = buffer.create (5)
            buffer.writeu8 (buf, 0, 100) -- varint for 100 bytes
            Lync.string.read (buf, 0, nil)
        end):toThrow ()
    end)
end)

describe ("array truncation", function (): ()
    it ("throws when elements exceed buffer", function (): ()
        expect (function (): ()
            local buf = buffer.create (3)
            buffer.writeu8 (buf, 0, 0xE8) -- varint 1000 (byte 1)
            buffer.writeu8 (buf, 1, 0x07) -- varint 1000 (byte 2)
            Lync.array (Lync.u8).read (buf, 0, nil)
        end):toThrow ()
    end)
end)

return nil
