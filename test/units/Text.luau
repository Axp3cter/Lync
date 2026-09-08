--!strict
--!optimize 2
-- One name carrying two string forms, and what each records about the symbols it takes.

local Base = require("@src/codec/Base")
local Text = require("@src/codec/Text")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local LOW = 0
local HIGH = 8

local function symbols(of: any): string?
    return Base.cell(of).params.symbols :: string?
end

return {
    -- The bare form records no symbol set, the one thing separating it from the alphabet form.
    Harness.case("text.bare-is-a-form", function()
        local of = Text.str(LOW, HIGH)
        Expect.equal(Base.cell(of).kind, "str")
        Expect.equal(symbols(of), nil)
        Expect.equal(Base.cell(of).params.min, LOW)
        Expect.equal(Base.cell(of).params.max, HIGH)
    end),

    -- The order is the whole of what a set says, since a symbol reaches a value by where it sits.
    Harness.case("text.alphabet-keeps-its-order", function()
        Expect.equal(symbols(Text.str.alphabet("abc", LOW, HIGH)), "abc")
        Expect.equal(symbols(Text.str.alphabet("cba", LOW, HIGH)), "cba")
        Expect.equal(Base.cell(Text.str.alphabet("abc", LOW, HIGH)).kind, "str")
    end),

    Harness.case("text.alphabet-refuses-a-repeat", function()
        local said = Expect.throws(function()
            Text.str.alphabet("abca", LOW, HIGH)
        end)
        Expect.holds(string.find(said, "each symbol once", 1, true) ~= nil, `it said "{said}"`)
        Expect.holds(string.find(said, "a is twice", 1, true) ~= nil, "it named none")
    end),

    Harness.case("text.alphabet-refuses-an-empty-set", function()
        Expect.throws(function()
            Text.str.alphabet("", LOW, HIGH)
        end, "at least one symbol")
        for _, value in { 1, true, {} } do
            local said = Expect.throws(function()
                Text.str.alphabet(value :: any, LOW, HIGH)
            end)
            Expect.holds(string.find(said, "a symbol set", 1, true) ~= nil, `it said "{said}"`)
        end
    end),

    -- The set is bytes: a character past ASCII is several, and the same one twice is a repeat.
    Harness.case("text.alphabet-walks-bytes", function()
        local wide = "\u{00E9}"
        Expect.equal(#wide, 2)
        Expect.equal(symbols(Text.str.alphabet(wide, LOW, HIGH)), wide)
        Expect.throws(function()
            Text.str.alphabet(wide .. wide, LOW, HIGH)
        end, "each symbol once")
    end),

    -- Every form counts the same way, and so do bytes nobody opens.
    Harness.case("text.counts-are-one-rule", function()
        Expect.throws(function()
            Text.str(HIGH, LOW)
        end, "in order")
        Expect.throws(function()
            Text.str.alphabet("abc", -1, HIGH)
        end, "from zero up")
        Expect.throws(function()
            Text.buffer(LOW, 1.5)
        end, "whole bounds")
    end),

    Harness.case("text.buffer-has-no-symbols", function()
        local of = Text.buffer(LOW, HIGH)
        Expect.equal(Base.cell(of).kind, "buffer")
        Expect.equal(symbols(of), nil)
        Expect.equal(Base.cell(of).params.max, HIGH)
    end),
}
