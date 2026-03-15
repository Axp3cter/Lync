--!strict
--!optimize 2
-- Struct, array, map throughput.

local Runner  = require(script.Parent.Parent.Runner)
local Channel = require(script.Parent.Parent.Parent.core.Channel)
local Lync    = require(script.Parent.Parent.Parent)

local group   = Runner.group
local measure = Runner.measure
local encode  = Runner.encode

-- Benchmarks -------------------------------------------------------------

group("Struct write/read", function(): ()
    local codec = Lync.struct({
        health = Lync.u16,
        x      = Lync.f32,
        y      = Lync.f32,
        z      = Lync.f32,
        name   = Lync.string,
    })

    local input = { health = 100, x = 1.5, y = 2.5, z = 3.5, name = "Player1" }
    local ch    = Channel.create()

    measure("struct write (5 fields)", function(): ()
        ch.cursor = 0
        table.clear(ch.refs)
        codec.write(ch, input)
    end, { batch = 100 })

    local encoded, _ = encode(codec, input)
    local buf        = buffer.create(encoded.cursor)
    buffer.copy(buf, 0, encoded.buff, 0, encoded.cursor)

    measure("struct read (5 fields)", function(): ()
        codec.read(buf, 0, nil)
    end, { batch = 100 })
end)

group("Array write/read", function(): ()
    local codec = Lync.array(Lync.u16)
    local small = { 1, 2, 3, 4, 5 }
    local large = table.create(100)
    for i = 1, 100 do
        large[i] = i
    end

    local ch = Channel.create()

    measure("array write (5 u16)", function(): ()
        ch.cursor = 0
        table.clear(ch.refs)
        codec.write(ch, small)
    end, { batch = 100 })

    measure("array write (100 u16)", function(): ()
        ch.cursor = 0
        table.clear(ch.refs)
        codec.write(ch, large)
    end, { batch = 50 })

    local encoded, _ = encode(codec, large)
    local buf        = buffer.create(encoded.cursor)
    buffer.copy(buf, 0, encoded.buff, 0, encoded.cursor)

    measure("array read (100 u16)", function(): ()
        codec.read(buf, 0, nil)
    end, { batch = 50 })
end)

return nil
