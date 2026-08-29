--!strict
--!optimize 2
--[[
    One name carrying seven string forms, and what each records about the symbols it takes.
]]

local Base = require ("@src/codec/Base")
local Lync = require ("@src")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

-- A count range every form here is built with, since none of them is about the count.
const LOW = 0
const HIGH = 8

-- The five presets, each with a symbol a case reads off it.
const PRESETS = table.freeze ({
    { name = "alphanum", holds = "z", lacks = "+" },
    { name = "base32", holds = "7", lacks = "1" },
    { name = "base64", holds = "/", lacks = " " },
    { name = "digits", holds = "9", lacks = "a" },
    { name = "hex", holds = "f", lacks = "F" },
})

-- Private -------------------------------------------------------------

-- The symbol set a declaration recorded, or nothing where it recorded none.
local function symbols (of: any): string? return Base.cell (of).params.symbols :: string? end

-- Public --------------------------------------------------------------

return {
    --[[
        The bare name is one of the seven forms, reached through the metamethod that is handed the
        table before the bounds. It records no symbol set, which is the one thing separating it
        from the alphabet form it shares a path with.
    ]]
    Harness.case ("text.bare-is-a-form", function ()
        local of = Lync.str (LOW, HIGH)

        Expect.equal (Base.cell (of).kind, "str")
        Expect.equal (symbols (of), nil)
        Expect.equal (Base.cell (of).params.min, LOW)
        Expect.equal (Base.cell (of).params.max, HIGH)
    end),

    --[[
        Each preset is one of the sets the module holds with the general form behind it, so the six
        forms are one path. What a case reads off one is a symbol it has and one it has not, since
        the set is the parameter's own business.
    ]]
    Harness.case ("text.presets", function ()
        for _, preset in PRESETS do
            local of = (Lync.str :: any)[preset.name] (LOW, HIGH)
            local held = symbols (of)

            Expect.holds (held ~= nil, `str.{preset.name} recorded no symbol set`)
            local said = held :: string

            local has = string.find (said, preset.holds, 1, true)
            Expect.holds (has ~= nil, `str.{preset.name} is missing {preset.holds}`)

            local lacks = string.find (said, preset.lacks, 1, true)
            Expect.holds (lacks == nil, `str.{preset.name} holds {preset.lacks}`)
        end
    end),

    --[[
        The one preset whose case is load-bearing, asked as the set itself rather than through a
        value. Sixteen symbols and no capital among them, which is the one preset a reader would
        guess the other way about.
    ]]
    Harness.case ("text.hex-is-one-case", function ()
        local held = symbols (Lync.str.hex (LOW, HIGH)) :: string

        Expect.holds (string.find (held, "f", 1, true) ~= nil, "hex has no f")
        Expect.equal (string.find (held, "F", 1, true), nil)
        Expect.equal (#held, 16)
    end),

    --[[
        A caller's own set is taken as it was written. The order is the whole of what it says, since
        a symbol reaches a value by where it sits, where an enum's names are a set a value is
        reached by and their order is incidental.
    ]]
    Harness.case ("text.alphabet-keeps-its-order", function ()
        local forwards = symbols (Lync.str.alphabet ("abc", LOW, HIGH))
        local backwards = symbols (Lync.str.alphabet ("cba", LOW, HIGH))

        Expect.equal (forwards, "abc")
        Expect.equal (backwards, "cba")
    end),

    --[[
        A set a caller wrote with a symbol in it twice, refused with the repeat named. Both halves
        are asked, since a refusal naming the rule alone leaves a caller holding sixty four
        characters and a sentence about one of them.
    ]]
    Harness.case ("text.alphabet-refuses-a-repeat", function ()
        local said = Expect.throws (function () Lync.str.alphabet ("abca", LOW, HIGH) end)

        Expect.holds (string.find (said, "each symbol once", 1, true) ~= nil, `it said "{said}"`)
        Expect.holds (string.find (said, "a is twice", 1, true) ~= nil, `it named none`)
    end),

    --[[
        A set of nothing, and a set that is no string at all. Neither is a set a character could be
        looked up in, and the first is the one a caller reaches by building the set in a loop that
        found nothing to put in it.
    ]]
    Harness.case ("text.alphabet-refuses-an-empty-set", function ()
        Expect.throws (function () Lync.str.alphabet ("", LOW, HIGH) end, "at least one symbol")

        for _, value in { 1, true, {} } do
            local said = Expect.throws (function () Lync.str.alphabet (value :: any, LOW, HIGH) end)
            Expect.holds (string.find (said, "a symbol set", 1, true) ~= nil, `it said "{said}"`)
        end
    end),

    --[[
        The set is bytes rather than characters, so a symbol past the ASCII range is several of them
        and each is a symbol. Two multi-byte characters sharing a byte are a repeat, which is what
        the walk sees and a walk over characters would not.
    ]]
    Harness.case ("text.alphabet-walks-bytes", function ()
        local wide = "\u{00E9}"
        Expect.equal (#wide, 2)

        -- The two bytes are distinct, so the set is legal and holds both of them.
        local held = symbols (Lync.str.alphabet (wide, LOW, HIGH))
        Expect.equal (held, wide)

        -- And the same character twice is the same two bytes twice, which is a repeat.
        Expect.throws (
            function () Lync.str.alphabet (wide .. wide, LOW, HIGH) end,
            "each symbol once"
        )
    end),

    --[[
        Every form counts the same way, and bytes nobody opens count that way too. The bounds test
        belongs to the declaration legality rather than to any of the six, so a mistake in them
        reads the same wherever it was made.
    ]]
    Harness.case ("text.counts-are-one-rule", function ()
        Expect.throws (function () Lync.str (HIGH, LOW) end, "in order")
        Expect.throws (function () Lync.str.hex (HIGH, LOW) end, "in order")
        Expect.throws (function () Lync.str.alphabet ("abc", -1, HIGH) end, "from zero up")
        Expect.throws (function () Lync.buffer (LOW, 1.5) end, "whole bounds")
    end),

    --[[
        Bytes nobody opens, carrying no set to be outside of. A buffer is a count and that many
        bytes, and a symbol set there would be a claim about what is inside something the library
        does not read.
    ]]
    Harness.case ("text.buffer-has-no-symbols", function ()
        local of = Lync.buffer (LOW, HIGH)

        Expect.equal (Base.cell (of).kind, "buffer")
        Expect.equal (symbols (of), nil)
        Expect.equal (Base.cell (of).params.max, HIGH)
    end),
}
