--!strict
-- The tooling asked its own questions.

local Reading = require ("./Reading")
local Ruling = require ("./Ruling")

local Cases = {}

-- Types ---------------------------------------------------------------

-- One question with a name on it. A body raises at its first wrong answer.
type Case = {
    read name: string,
    read run: () -> (),
}

-- Private -------------------------------------------------------------

-- Questions the run asked, which is the number a passing line reports.
local asked = 0

-- A multi-line input, built line by line.
local function joined (parts: { string }): string return table.concat (parts, "\n") end

-- Enough of a value to recognize it in a failure.
local function show (value: unknown): string
    if typeof (value) == "string" then return `"{value}"` end
    if typeof (value) ~= "table" then return tostring (value) end

    local parts = {}
    for _, one in value :: { unknown } do
        table.insert (parts, show (one))
    end
    return `[{table.concat (parts, ", ")}]`
end

local function holds (ok: boolean, why: string)
    asked += 1
    if ok then return end
    error (why, 0)
end

--[[
    Structural equality through the comparison under test, which is safe in one direction only.
    `reading.same` asks about it with `holds` and never through itself, so a comparison that
    answered yes to everything would fail its own case before it could carry another one.
]]
local function equal (got: unknown, want: unknown)
    asked += 1
    if Reading.same (got, want) then return end
    error (`{show (got)}, expected {show (want)}`, 0)
end

--[[
    The question the constant hunt asks of a stripped source: is this number still standing? Asked
    the hunt's own way, frontier patterns included, so a case is reading what the check reads rather
    than a shape resembling it.
]]
local function survives (source: string, value: string): boolean
    local pattern = `%f[%w]{string.gsub (value, "%p", "%%%0")}%f[%W]`
    return string.find (Reading.stripped (source), pattern) ~= nil
end

--[[
    Every case, in the order a reader meets them: the line splitter everything else is built on,
    then the readers over it.
]]
local CASES: { Case } = {
    --[[
        A line is what an editor shows on one row, which is what a fault has to name to be worth
        reading.
    ]]
    {
        name = "reading.lines",
        run = function ()
            equal (Reading.lines (""), { "" })
            equal (Reading.lines ("one"), { "one" })
            equal (Reading.lines ("one\ntwo"), { "one", "two" })
            equal (Reading.lines ("one\n"), { "one", "" })
            equal (Reading.lines ("\n"), { "", "" })
            equal (Reading.lines ("\n\n"), { "", "", "" })
            equal (Reading.lines ("a\n\nb"), { "a", "", "b" })
            equal (Reading.lines ("a\r\nb"), { "a\r", "b" })
            equal (#Reading.lines (joined ({ "a", "b", "c" })), 3)
        end,
    },

    -- Code quoted into a sentence, taken out before the sentence is read.
    {
        name = "reading.quoted",
        run = function ()
            equal (Reading.quoted ("a `b` c"), "a `` c")
            equal (Reading.quoted ("`a` and `b`"), "`` and ``")
            equal (Reading.quoted ("no marks here"), "no marks here")
            equal (Reading.quoted (""), "")
            equal (Reading.quoted ("an unclosed ` mark"), "an unclosed ` mark")
            equal (Reading.quoted ("``"), "``")
            equal (Reading.quoted ("`a*b`"), "``")
            equal (Reading.quoted ("keep * this"), "keep * this")

            -- A module named in a span stays, since naming a home is what a second site says.
            equal (Reading.quoted ("read `src/wire/Bytes` for it"), "read `src/wire/Bytes` for it")
            equal (Reading.quoted ("`fixtures/Doubles`"), "`fixtures/Doubles`")
            equal (Reading.quoted ("`Protocol.BIT_CEILING`"), "``")
        end,
    },

    --[[
        Prose taken out of source, which is the inverse of the reader above it and the input the
        wire constant hunt reads.
    ]]
    {
        name = "reading.stripped",
        run = function ()
            holds (survives ("local a = 4096", "4096"), "a bare number left")
            holds (survives ("local a = 4096 + b", "4096"), "a number in an expression left")
            holds (not survives ("-- see 4096", "4096"), "a line comment stayed")
            holds (not survives ("local a = b -- see 4096", "4096"), "a trailing comment stayed")
            holds (not survives ("--[[ see 4096 ]]", "4096"), "a one-line block stayed")
            holds (
                not survives (joined ({ "--[[", "    see 4096", "]]" }), "4096"),
                "a block stayed"
            )
            holds (not survives ('local a = "4096"', "4096"), "a quoted number stayed")
            holds (not survives ("local a = '4096'", "4096"), "a single quoted number stayed")
            holds (not survives ("local a = `4096`", "4096"), "an interpolated number stayed")

            local phrased = '--[[ a phrase in "quotes" and 4096 ]]'
            holds (not survives (phrased, "4096"), "a block holding a quote stayed")

            local apostrophe = joined ({ "--[[ it's fine", "    and 4096", "]]" })
            holds (not survives (apostrophe, "4096"), "a block holding one apostrophe stayed")

            local hyphened = 'local note, size = "a -- b", 4096'
            holds (survives (hyphened, "4096"), "a double hyphen in a string ate the code after it")
            holds (not survives (hyphened, "42"), "a number nobody wrote was found")

            local closing = '--[[ see "]]" and 4096 ]]'
            holds (not survives (closing, "4096"), "a block ended inside a quoted phrase")
        end,
    },

    -- The two streams a Luau file speaks to a person in, line for line.
    {
        name = "reading.prosed",
        run = function ()
            local source = joined ({
                "local Thing = {}",
                "-- a line comment",
                'local a = "-- not a comment"',
                "local b = `a message`",
                "--[[",
                "    a block",
                "]]",
                "local c = 1 -- trailing",
            })

            local sentences, messages = Reading.prosed (source)
            equal (#sentences, 8)
            equal (#messages, 8)

            equal (sentences[1], "")
            equal (sentences[2], "-- a line comment")
            equal (sentences[3], "")
            equal (sentences[4], "")
            equal (sentences[5], "--[[")
            equal (sentences[6], "    a block")
            equal (sentences[7], "]]")
            equal (sentences[8], "-- trailing")

            equal (messages[4], "`a message`")
            for index, line in messages do
                if index == 4 then continue end
                equal (line, "")
            end

            local closed = Reading.prosed (joined ({ "--[[ opened and closed ]]", "local a = 1" }))
            equal (closed[1], "--[[ opened and closed ]]")
            equal (closed[2], "")

            local inner = Reading.prosed (joined ({ "--[[", "    a `span` inside", "]]" }))
            equal (inner[2], "    a `` inside")

            local spanned = Reading.prosed ("-- a `*` mark")
            equal (spanned[1], "-- a `` mark")
        end,
    },

    -- A document's prose, with everything a reader was never meant to read as prose taken out.
    {
        name = "reading.written",
        run = function ()
            local document = joined ({
                "prose with a `span` in it",
                "```luau",
                "local a = 2 * 3",
                "```",
                "more prose",
            })

            equal (Reading.written (document), {
                "prose with a `` in it",
                "",
                "",
                "",
                "more prose",
            })

            equal (Reading.written (joined ({ "```", "inside" })), { "", "" })
            equal (Reading.written ("plain"), { "plain" })
            equal (Reading.written (joined ({ "    ```", "indented fence", "    ```" })), {
                "",
                "",
                "",
            })
        end,
    },

    --[[
        The prose a declaration carries. The delimiters and a statement beside a tooltip are both
        left out, since a semicolon ending one is syntax and only the tooltip is prose.
    ]]
    {
        name = "reading.declared",
        run = function ()
            local source = joined ({
                "declare namespace Held {",
                "    /** one line of prose */ readonly a: number;",
                "    // a slash comment",
                "    /**",
                "     * a doc line",
                "     */",
                "    readonly b: string;",
                "}",
            })

            equal (Reading.declared (source), {
                "",
                " one line of prose ",
                "// a slash comment",
                "",
                " a doc line",
                "     ",
                "",
                "",
            })

            equal (Reading.declared ("plain"), { "" })
        end,
    },

    -- A table row, which is the one document line the width gate forgives.
    {
        name = "reading.tabular",
        run = function ()
            holds (Reading.tabular ("| a | b |"), "a row was not read as one")
            holds (Reading.tabular ("    | a |"), "an indented row was not read as one")
            holds (Reading.tabular ("|"), "a bare pipe was not read as a row")
            holds (not Reading.tabular ("a | b"), "prose with a pipe was read as a row")
            holds (not Reading.tabular (""), "an empty line was read as a row")
            holds (not Reading.tabular ("text"), "prose was read as a row")
        end,
    },

    -- Two decoded configs held against each other, in both directions.
    {
        name = "reading.same",
        run = function ()
            holds (Reading.same (1, 1), "a number did not match itself")
            holds (Reading.same ("a", "a"), "a string did not match itself")
            holds (Reading.same (true, true), "a boolean did not match itself")
            holds (Reading.same (nil, nil), "nothing did not match nothing")
            holds (not Reading.same (1, 2), "two numbers matched")
            holds (not Reading.same (true, false), "two booleans matched")
            holds (not Reading.same (1, "1"), "a number matched its spelling")
            holds (not Reading.same (nil, 1), "nothing matched something")
            holds (not Reading.same ({ a = 1 }, 5), "a table matched a number")
            holds (not Reading.same (5, { a = 1 }), "a number matched a table")

            holds (Reading.same ({}, {}), "two empty tables did not match")
            holds (Reading.same ({ 1, 2 }, { 1, 2 }), "two equal lists did not match")
            holds (Reading.same ({ a = { b = 1 } }, { a = { b = 1 } }), "nesting did not match")

            holds (not Reading.same ({ 1, 2 }, { 1, 2, 3 }), "a longer list matched")
            holds (not Reading.same ({ 1, 2, 3 }, { 1, 2 }), "a shorter list matched")
            holds (not Reading.same ({ a = 1 }, { a = 1, b = 2 }), "an extra key on the right")
            holds (not Reading.same ({ a = 1, b = 2 }, { a = 1 }), "an extra key on the left")
            holds (not Reading.same ({ a = { b = 1 } }, { a = { b = 2 } }), "nesting differed")
            holds (not Reading.same ({ a = 1 }, { a = "1" }), "a value matched its spelling")
        end,
    },

    --[[
        A version read off whatever a tool prints, which is the only way the toolchain gate knows
        the machine matches the manifest.
    ]]
    {
        name = "reading.version",
        run = function ()
            equal (Reading.versionIn ("stylua 2.5.2"), "2.5.2")
            equal (Reading.versionIn ("darklua 0.19.0"), "0.19.0")
            equal (Reading.versionIn ("lune 0.10.5"), "0.10.5")
            equal (Reading.versionIn ("Rojo 7.7.0"), "7.7.0")
            equal (Reading.versionIn ("wally 0.3.2"), "0.3.2")
            equal (Reading.versionIn ("1.69.0"), "1.69.0")

            equal (Reading.versionIn ("1.2"), "1.2")
            equal (Reading.versionIn ("v1.0.0-rc.1"), "1.0.0")
            equal (Reading.versionIn ("lune2 0.10.5"), "0.10.5")
            equal (Reading.versionIn ("no version here"), nil)
            equal (Reading.versionIn (""), nil)
            equal (Reading.versionIn ("7"), nil)
        end,
    },

    -- A divider, which is the one comment kind with no prose in it.
    {
        name = "reading.divides",
        run = function ()
            holds (Reading.divides ("-- Types ------------"), "a divider was read as prose")
            holds (Reading.divides ("    -- Public -----"), "an indented divider was missed")
            holds (Reading.divides ("-- The one home ---"), "a two word section was missed")

            holds (not Reading.divides ("-- a sentence"), "a sentence was read as a divider")
            holds (not Reading.divides ("-- ends in a dash -"), "one dash is a hyphen")
            holds (not Reading.divides ("local at = 1"), "code is no divider")
            holds (not Reading.divides (""), "nothing is no divider")
        end,
    },

    -- A divider as the one it would be at the column.
    {
        name = "reading.dashed",
        run = function ()
            local held = Reading.dashed ("-- Types ---") :: string
            equal (#held, 72)
            equal (string.sub (held, 1, 9), "-- Types ")

            -- Already at the column, which is the answer being the line it was handed.
            equal (Reading.dashed (held), held)

            -- The indent counts toward it, since the edge a reader sees is the whole line.
            local under = Reading.dashed ("    -- Public ---") :: string
            equal (#under, 72)
            equal (string.sub (under, 1, 14), "    -- Public ")

            equal (Reading.dashed ("-- a sentence"), nil)
            equal (Reading.dashed ("local at = 1"), nil)
            equal (Reading.dashed (""), nil)
        end,
    },

    -- The words a sentence says something with, which is every word a name could also be.
    {
        name = "reading.words",
        run = function ()
            equal (Reading.words ("the width of a field"), { "width", "field" })
            equal (Reading.words ("WIDTH of the Field"), { "width", "field" })
            equal (Reading.words ("and the of it"), {})
            equal (Reading.words (""), {})
            equal (Reading.words ("max-bytes, held"), { "max", "bytes", "held" })
            equal (Reading.words ("2 ^ 52"), {})
        end,
    },

    -- The words a name is made of, which is a phrase written without spaces.
    {
        name = "reading.names",
        run = function ()
            local held = Reading.names ("local maxBytes = of.blockBytes")
            holds (held.max and held.bytes and held.block, "a hump was left joined")
            holds (held["local"] ~= nil, "a keyword is a name to a reader all the same")

            local loud = Reading.names ("BIT_CEILING")
            holds (loud.bit and loud.ceiling, "a shouted name was left joined")

            local bare = Reading.names ("of[at] = 1")
            holds (bare.of and bare.at, "a short name was lost")
            equal (Reading.names ("")["x"], nil)
        end,
    },

    -- How much of a sentence is already in the names beside it.
    {
        name = "reading.echoed",
        run = function ()
            equal (Reading.echoed ("the width", "local width = 1"), 1)
            equal (Reading.echoed ("the max bytes", "local maxBytes = 1"), 1)
            equal (Reading.echoed ("nothing of the sort", "local width = 1"), 0)
            equal (Reading.echoed ("", "local width = 1"), 0)
            equal (Reading.echoed ("and the of", "local width = 1"), 0)

            -- Half of it, which is the shape a label over a call has and a restatement has not.
            equal (Reading.echoed ("the width, once", "local width = 1"), 0.5)
        end,
    },
}

-- Public --------------------------------------------------------------

--[[
    Every case, and what the run answered. No case stops the run, because one pass should report
    every reader that is wrong rather than only the first, which is the rule every other step here
    follows.
]]
function Cases.run (): Ruling.Ruling
    asked = 0
    local failed = {}

    for _, case in CASES do
        local ok, caught = pcall (case.run)
        if not ok then table.insert (failed, `{case.name}: {tostring (caught)}`) end
    end

    if #failed > 0 then return { ok = false, note = table.concat (failed, ", ") } end
    return { ok = true, note = `{asked} answers over {#CASES} cases` }
end

return table.freeze (Cases)
