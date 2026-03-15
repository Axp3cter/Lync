--!strict
--!optimize 2
local Compress = require (script.Parent.Parent.Parent.transport.Compress)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

local function make (size: number, pat: (i: number) -> number): buffer
    local b = buffer.create (size)
    for i = 0, size - 1 do
        buffer.writeu8 (b, i, pat (i))
    end
    return b
end
local function eq (a: buffer, b: buffer): boolean
    if buffer.len (a) ~= buffer.len (b) then
        return false
    end
    for i = 0, buffer.len (a) - 1 do
        if buffer.readu8 (a, i) ~= buffer.readu8 (b, i) then
            return false
        end
    end
    return true
end

describe ("Compress below threshold", function (): ()
    it ("returns original", function (): ()
        local s = make (16, function (i)
            return i
        end)
        local p, c = Compress.pack (s)
        expect (c):toBe (false)
        expect (eq (p, s)):toBe (true)
    end)
    it ("empty buffer", function (): ()
        local p, c = Compress.pack (buffer.create (0))
        expect (c):toBe (false)
        expect (buffer.len (p)):toBe (0)
    end)
    it ("at threshold (32)", function (): ()
        local s = make (32, function (i)
            return i
        end)
        local p, c = Compress.pack (s)
        if not c then
            expect (eq (p, s)):toBe (true)
        end
    end)
end)

describe ("Compress round-trip identity", function (): ()
    it ("repetitive (best case)", function (): ()
        local s = make (256, function ()
            return 0xAA
        end)
        local p, c = Compress.pack (s)
        expect (c):toBe (true)
        expect (buffer.len (p) < 256):toBe (true)
        expect (eq (Compress.unpack (p), s)):toBe (true)
    end)
    it ("sequential", function (): ()
        local s = make (256, function (i)
            return i % 256
        end)
        local p, c = Compress.pack (s)
        if c then
            expect (eq (Compress.unpack (p), s)):toBe (true)
        else
            expect (eq (p, s)):toBe (true)
        end
    end)
    it ("repeated subsequence", function (): ()
        local s = make (512, function (i)
            return (i % 16) * 3
        end)
        local p, c = Compress.pack (s)
        expect (c):toBe (true)
        expect (eq (Compress.unpack (p), s)):toBe (true)
    end)
    it ("mixed pattern", function (): ()
        local s = make (1024, function (i)
            return if i % 4 == 0 then 0 else (i * 7 + 13) % 256
        end)
        local p, c = Compress.pack (s)
        if c then
            expect (eq (Compress.unpack (p), s)):toBe (true)
        else
            expect (eq (p, s)):toBe (true)
        end
    end)
    it ("all zeros 1KB", function (): ()
        local s = buffer.create (1024)
        local p, c = Compress.pack (s)
        expect (c):toBe (true)
        expect (eq (Compress.unpack (p), s)):toBe (true)
    end)
    it ("all 0xFF 512B", function (): ()
        local s = make (512, function ()
            return 0xFF
        end)
        local p, c = Compress.pack (s)
        expect (c):toBe (true)
        expect (eq (Compress.unpack (p), s)):toBe (true)
    end)
    it ("2KB stress", function (): ()
        local s = make (2048, function (i)
            return (i * 31 + i // 16) % 256
        end)
        local p, c = Compress.pack (s)
        if c then
            expect (eq (Compress.unpack (p), s)):toBe (true)
        end
    end)
end)

describe ("Compress skip when no savings", function (): ()
    it ("pseudo-random not smaller", function (): ()
        local s = make (256, function (i)
            return (i * 131 + 17) % 256
        end)
        local p, c = Compress.pack (s)
        if not c then
            expect (eq (p, s)):toBe (true)
        end
    end)
end)

describe ("Compress.unpack edge", function (): ()
    it ("empty → empty", function (): ()
        expect (buffer.len (Compress.unpack (buffer.create (0)))):toBe (0)
    end)
end)

return nil
