--!strict
--!optimize 2
-- Compress.test.luau — Pack/unpack identity, threshold bypass, repetitive data.

local Runner   = require(script.Parent.Parent.Runner)
local Compress = require(script.Parent.Parent.Parent.transport.Compress)

local describe = Runner.describe
local it       = Runner.it
local expect   = Runner.expect

-- Helpers ----------------------------------------------------------------

local function makeBuffer(size: number, pattern: (i: number) -> number): buffer
    local buf = buffer.create(size)
    for i = 0, size - 1 do
        buffer.writeu8(buf, i, pattern(i))
    end
    return buf
end

local function buffersEqual(a: buffer, b: buffer): boolean
    local lenA = buffer.len(a)
    if lenA ~= buffer.len(b) then return false end
    for i = 0, lenA - 1 do
        if buffer.readu8(a, i) ~= buffer.readu8(b, i) then return false end
    end
    return true
end

-- Tests ------------------------------------------------------------------

describe("Compress.pack below threshold", function(): ()
    it("returns original buffer unchanged", function(): ()
        local src = makeBuffer(64, function(i: number): number return i end)
        local packed, wasCompressed = Compress.pack(src)
        expect(wasCompressed):toBe(false)
        expect(buffersEqual(packed, src)):toBe(true)
    end)
    it("handles empty buffer", function(): ()
        local src = buffer.create(0)
        local packed, wasCompressed = Compress.pack(src)
        expect(wasCompressed):toBe(false)
        expect(buffer.len(packed)):toBe(0)
    end)
end)

describe("Compress.pack + unpack identity", function(): ()
    it("round-trips repetitive data (high compression)", function(): ()
        local src = makeBuffer(256, function(_i: number): number return 0xAA end)
        local packed, wasCompressed = Compress.pack(src)
        expect(wasCompressed):toBe(true)
        expect(buffer.len(packed) < buffer.len(src)):toBe(true)

        local unpacked = Compress.unpack(packed)
        expect(buffersEqual(unpacked, src)):toBe(true)
    end)
    it("round-trips sequential data", function(): ()
        local src = makeBuffer(256, function(i: number): number return i % 256 end)
        local packed, wasCompressed = Compress.pack(src)

        if wasCompressed then
            local unpacked = Compress.unpack(packed)
            expect(buffersEqual(unpacked, src)):toBe(true)
        else
            expect(buffersEqual(packed, src)):toBe(true)
        end
    end)
    it("round-trips pattern with repeated subsequences", function(): ()
        local src = makeBuffer(512, function(i: number): number
            return (i % 16) * 3
        end)
        local packed, wasCompressed = Compress.pack(src)
        expect(wasCompressed):toBe(true)

        local unpacked = Compress.unpack(packed)
        expect(buffersEqual(unpacked, src)):toBe(true)
    end)
    it("round-trips large buffer of mixed data", function(): ()
        local src = makeBuffer(1024, function(i: number): number
            return if i % 4 == 0 then 0 else (i * 7 + 13) % 256
        end)
        local packed, wasCompressed = Compress.pack(src)

        if wasCompressed then
            local unpacked = Compress.unpack(packed)
            expect(buffersEqual(unpacked, src)):toBe(true)
        else
            expect(buffersEqual(packed, src)):toBe(true)
        end
    end)
end)

describe("Compress.pack skips when no savings", function(): ()
    it("returns original when random-like data does not compress", function(): ()
        local src = makeBuffer(256, function(i: number): number
            return (i * 131 + 17) % 256
        end)
        local packed, wasCompressed = Compress.pack(src)

        if not wasCompressed then
            expect(buffersEqual(packed, src)):toBe(true)
        end
    end)
end)

describe("Compress.unpack edge cases", function(): ()
    it("returns empty buffer on empty input", function(): ()
        local result = Compress.unpack(buffer.create(0))
        expect(buffer.len(result)):toBe(0)
    end)
end)

return nil
