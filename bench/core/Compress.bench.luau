--!strict
--!optimize 2
-- Compress.bench.luau — LZSS pack/unpack throughput at various data patterns.

local Runner   = require(script.Parent.Parent.Runner)
local Compress = require(script.Parent.Parent.Parent.transport.Compress)

local group   = Runner.group
local measure = Runner.measure

-- Helpers ----------------------------------------------------------------

local function makeBuffer(size: number, pattern: (i: number) -> number): buffer
    local buf = buffer.create(size)
    for i = 0, size - 1 do
        buffer.writeu8(buf, i, pattern(i))
    end
    return buf
end

-- Benchmarks -------------------------------------------------------------

local SLOW = { samples = 1000, warmup = 100, batch = 1 }

group("Compress.pack", function(): ()
    local repetitive  = makeBuffer(1024, function(_i: number): number return 0xAA end)
    local nonRepeating = makeBuffer(1024, function(i: number): number return i % 256 end)
    local noisy       = makeBuffer(1024, function(i: number): number return (i * 131 + 17) % 256 end)

    measure("pack 1KB repetitive (best case)", function(): ()
        Compress.pack(repetitive)
    end, SLOW)

    measure("pack 1KB non-repeating (worst case)", function(): ()
        Compress.pack(nonRepeating)
    end, SLOW)

    measure("pack 1KB noisy (worst case)", function(): ()
        Compress.pack(noisy)
    end, SLOW)
end)

group("Compress.unpack", function(): ()
    local repetitive = makeBuffer(1024, function(_i: number): number return 0xAA end)
    local packed, _  = Compress.pack(repetitive)

    measure("unpack 1KB repetitive", function(): ()
        Compress.unpack(packed)
    end, SLOW)
end)

return nil
