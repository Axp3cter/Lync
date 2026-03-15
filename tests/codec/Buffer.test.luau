--!strict
--!optimize 2
-- Buffer.test.luau — Round-trip tests for raw buffer codec.

local Runner = require(script.Parent.Parent.Runner)
local Lync   = require(script.Parent.Parent.Parent)

local describe  = Runner.describe
local it        = Runner.it
local expect    = Runner.expect
local roundTrip = Runner.roundTrip

-- Tests ------------------------------------------------------------------

describe("Buffer", function(): ()
    it("round-trips empty buffer", function(): ()
        local input  = buffer.create(0)
        local result = roundTrip(Lync.buff, input)
        expect(buffer.len(result)):toBe(0)
    end)
    it("round-trips small buffer", function(): ()
        local input = buffer.create(4)
        buffer.writeu32(input, 0, 0xDEADBEEF)

        local result = roundTrip(Lync.buff, input)
        expect(buffer.len(result)):toBe(4)
        expect(buffer.readu32(result, 0)):toBe(0xDEADBEEF)
    end)
    it("round-trips 1KB buffer", function(): ()
        local input = buffer.create(1024)
        for i = 0, 255 do
            buffer.writeu8(input, i, i)
        end

        local result = roundTrip(Lync.buff, input)
        expect(buffer.len(result)):toBe(1024)
        expect(buffer.readu8(result, 0)):toBe(0)
        expect(buffer.readu8(result, 255)):toBe(255)
    end)
    it("empty buffer uses only varint overhead", function(): ()
        local _, written, _ = roundTrip(Lync.buff, buffer.create(0))
        expect(written):toBe(1)
    end)
end)

return nil
