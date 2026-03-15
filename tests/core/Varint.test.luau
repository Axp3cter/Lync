--!strict
--!optimize 2
-- Varint.test.luau — Boundary tests for LEB128 variable-length integer codec.

local Channel = require (script.Parent.Parent.Parent.core.Channel)
local Runner = require (script.Parent.Parent.Runner)
local Varint = require (script.Parent.Parent.Parent.core.Varint)

local describe = Runner.describe
local it = Runner.it
local expect = Runner.expect

-- Tests ------------------------------------------------------------------

describe ("Varint.write + read", function (): ()
    local function roundTrip (value: number): (number, number)
        local ch = Channel.create ()
        Varint.write (ch, value)

        local buf = buffer.create (ch.cursor)
        buffer.copy (buf, 0, ch.buff, 0, ch.cursor)
        return Varint.read (buf, 0)
    end

    it ("round-trips 0", function (): ()
        local value, bytes = roundTrip (0)
        expect (value):toBe (0)
        expect (bytes):toBe (1)
    end)
    it ("round-trips 127 (max single byte)", function (): ()
        local value, bytes = roundTrip (127)
        expect (value):toBe (127)
        expect (bytes):toBe (1)
    end)
    it ("round-trips 128 (first two-byte value)", function (): ()
        local value, bytes = roundTrip (128)
        expect (value):toBe (128)
        expect (bytes):toBe (2)
    end)
    it ("round-trips 16383 (max two-byte value)", function (): ()
        local value, bytes = roundTrip (16383)
        expect (value):toBe (16383)
        expect (bytes):toBe (2)
    end)
    it ("round-trips 16384 (first three-byte value)", function (): ()
        local value, bytes = roundTrip (16384)
        expect (value):toBe (16384)
        expect (bytes):toBe (3)
    end)
    it ("round-trips max u32", function (): ()
        local value, _ = roundTrip (4294967295)
        expect (value):toBe (4294967295)
    end)
    it ("round-trips 256", function (): ()
        local value, _ = roundTrip (256)
        expect (value):toBe (256)
    end)
    it ("round-trips 65535", function (): ()
        local value, _ = roundTrip (65535)
        expect (value):toBe (65535)
    end)
end)

describe ("Varint validation", function (): ()
    it ("throws on negative value", function (): ()
        expect (function (): ()
            local ch = Channel.create ()
            Varint.write (ch, -1)
        end):toThrow ("negative")
    end)
    it ("throws on value exceeding u32 max", function (): ()
        expect (function (): ()
            local ch = Channel.create ()
            Varint.write (ch, 4294967296)
        end):toThrow ("exceeds u32 max")
    end)
end)

describe ("Varint.read bounds safety", function (): ()
    it ("throws on empty buffer", function (): ()
        expect (function (): ()
            Varint.read (buffer.create (0), 0)
        end):toThrow ("exceeds buffer bounds")
    end)
    it ("throws on truncated multi-byte varint", function (): ()
        expect (function (): ()
            local buf = buffer.create (1)
            buffer.writeu8 (buf, 0, 0x80)
            Varint.read (buf, 0)
        end):toThrow ("exceeds buffer bounds")
    end)
end)

return nil
