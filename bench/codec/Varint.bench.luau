--!strict
--!optimize 2
-- Varint throughput.

local Channel = require (script.Parent.Parent.Parent.core.Channel)
local Runner = require (script.Parent.Parent.Runner)
local Varint = require (script.Parent.Parent.Parent.codec.Varint)

local group = Runner.group
local measure = Runner.measure

-- Benchmarks -------------------------------------------------------------

group ("Varint write", function (): ()
    local ch = Channel.create ()

    measure ("write 0 (1 byte)", function (): ()
        ch.cursor = 0
        Varint.write (ch, 0)
    end)

    measure ("write 127 (1 byte)", function (): ()
        ch.cursor = 0
        Varint.write (ch, 127)
    end)

    measure ("write 16384 (3 bytes)", function (): ()
        ch.cursor = 0
        Varint.write (ch, 16384)
    end)

    measure ("write max u32 (5 bytes)", function (): ()
        ch.cursor = 0
        Varint.write (ch, 4294967295)
    end)
end)

group ("Varint read", function (): ()
    local ch = Channel.create ()

    Varint.write (ch, 127)
    local buf1 = buffer.create (ch.cursor)
    buffer.copy (buf1, 0, ch.buff, 0, ch.cursor)

    ch.cursor = 0
    Varint.write (ch, 4294967295)
    local buf5 = buffer.create (ch.cursor)
    buffer.copy (buf5, 0, ch.buff, 0, ch.cursor)

    measure ("read 1-byte varint", function (): ()
        Varint.read (buf1, 0)
    end)

    measure ("read 5-byte varint", function (): ()
        Varint.read (buf5, 0)
    end)
end)

return nil
