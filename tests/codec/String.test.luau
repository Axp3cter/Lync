--!strict
--!optimize 2
-- String.test.luau — Round-trip tests for varint-prefixed string codec.

local Runner = require(script.Parent.Parent.Runner)
local Lync   = require(script.Parent.Parent.Parent)

local describe  = Runner.describe
local it        = Runner.it
local expect    = Runner.expect
local roundTrip = Runner.roundTrip

-- Tests ------------------------------------------------------------------

describe("String", function(): ()
    it("round-trips empty string", function(): ()
        expect(roundTrip(Lync.string, "")):toBe("")
    end)
    it("round-trips short ASCII", function(): ()
        expect(roundTrip(Lync.string, "hello")):toBe("hello")
    end)
    it("round-trips UTF-8", function(): ()
        expect(roundTrip(Lync.string, "日本語テスト")):toBe("日本語テスト")
    end)
    it("round-trips 1000-char string", function(): ()
        local long = string.rep("a", 1000)
        expect(roundTrip(Lync.string, long)):toBe(long)
    end)
    it("empty string uses only varint overhead", function(): ()
        local _, written, _ = roundTrip(Lync.string, "")
        expect(written):toBe(1)
    end)
    it("5-char string uses 1 + 5 bytes", function(): ()
        local _, written, _ = roundTrip(Lync.string, "abcde")
        expect(written):toBe(6)
    end)
end)

return nil
