--!strict
--!optimize 2
-- Fixed-size codec throughput.

local Channel = require (script.Parent.Parent.Parent.core.Channel)
local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)

local group = Runner.group
local measure = Runner.measure
local encode = Runner.encode

-- Benchmarks -------------------------------------------------------------

group ("Primitive write", function (): ()
    local ch = Channel.create ()

    measure ("u8 write", function (): ()
        ch.cursor = 0
        Lync.u8.write (ch, 255)
    end)

    measure ("u16 write", function (): ()
        ch.cursor = 0
        Lync.u16.write (ch, 65535)
    end)

    measure ("u32 write", function (): ()
        ch.cursor = 0
        Lync.u32.write (ch, 4294967295)
    end)

    measure ("f32 write", function (): ()
        ch.cursor = 0
        Lync.f32.write (ch, 3.14)
    end)

    measure ("f64 write", function (): ()
        ch.cursor = 0
        Lync.f64.write (ch, math.pi)
    end)

    measure ("bool write", function (): ()
        ch.cursor = 0
        Lync.bool.write (ch, true)
    end)
end)

group ("Primitive read", function (): ()
    local u8Ch, _ = encode (Lync.u8, 255)
    local u8Buf = buffer.create (u8Ch.cursor)
    buffer.copy (u8Buf, 0, u8Ch.buff, 0, u8Ch.cursor)

    local f64Ch, _ = encode (Lync.f64, math.pi)
    local f64Buf = buffer.create (f64Ch.cursor)
    buffer.copy (f64Buf, 0, f64Ch.buff, 0, f64Ch.cursor)

    measure ("u8 read", function (): ()
        Lync.u8.read (u8Buf, 0, nil)
    end)

    measure ("f64 read", function (): ()
        Lync.f64.read (f64Buf, 0, nil)
    end)
end)

return nil
