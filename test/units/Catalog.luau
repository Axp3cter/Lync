--!strict
--!optimize 2
--[[
    The diagnosis rows alone: what each says, what it declares, and the line one composes into.
]]

local Catalog = require ("@src/kernel/Catalog")
local Log = require ("@src/kernel/Log")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

-- The name a brace holds, in the pattern the composer reads a template with.
const HELD = "{(%w+)}"

-- The scope every code is under, and the case a name is expected to be written in.
const SCOPE = "drop"
const SPELLED = "^%l[%l-]*$"

-- Facts a case hands over, which are whatever a raising site would have.
const PATH = "roster.hp"
const WANTED = "a number from 0 to 100"
const GOT = "true"

-- Types ---------------------------------------------------------------

type Entry = Catalog.Entry

-- Private -------------------------------------------------------------

-- Every name a template holds in braces, in the order it holds them.
local function braced (of: Entry): { string }
    local out = {}
    for name in string.gmatch (of.template, HELD) do
        table.insert (out, name)
    end
    return out
end

-- A set of the names a list holds, which is what the two halves of a row are compared as.
local function setOf (names: { string }): { [string]: boolean }
    local out: { [string]: boolean } = {}
    for _, name in names do
        out[name] = true
    end
    return out
end

-- Every key a row declares, each with a fact behind it, which is what a raising site hands over.
local function filled (of: Entry): { [string]: unknown }
    local out: { [string]: unknown } = {}
    for _, key in of.keys do
        out[key] = `<{key}>`
    end
    return out
end

-- Public --------------------------------------------------------------

return {
    --[[
        Every code held to the spelling a caller is promised will never change, read off the table
        rather than off a list written here. A scope and a name in the case a greppable id is
        written in, which is what a branch in somebody else's code matches on.
    ]]
    Harness.case ("catalog.codes-are-scoped", function ()
        local counted = 0
        for code in Catalog.entries do
            counted += 1

            local scope, name = string.match (code, "^(%w+)%.(.*)$")
            Expect.equal (scope, SCOPE)
            Expect.holds (name ~= nil and string.match (name, SPELLED) ~= nil, `{code} is spelled`)
        end

        Expect.holds (counted > 0, "the catalogue holds no rows at all")
    end),

    --[[
        A template naming something no key declares is a line with a brace left in it. The two are
        held to each other exactly, in both directions, because either half on its own is
        satisfied by a row that says nothing.
    ]]
    Harness.case ("catalog.templates-name-declared-keys", function ()
        for code, entry in Catalog.entries do
            local declared = setOf (entry.keys)

            for _, name in braced (entry) do
                local why = `{code} names {name} and declares no key for it`
                Expect.holds (declared[name] == true, why)
            end
        end
    end),

    --[[
        And a key no template names is a fact the record carries and never says. A caller reads the
        fact rather than the sentence, so an undeclared one is not a fault, but one declared and
        never composed is a row promising a word it does not use.
    ]]
    Harness.case ("catalog.keys-are-all-named", function ()
        for code, entry in Catalog.entries do
            local said = setOf (braced (entry))

            for _, key in entry.keys do
                Expect.holds (said[key] == true, `{code} declares {key} and never says it`)
            end
        end
    end),

    --[[
        Every row and every list in it is frozen. A caller is handed the code and reads the facts,
        and the catalogue itself is what a gate walks, so a row somebody could write to would be a
        diagnosis that reads one way in a place and another in the run that checked it.
    ]]
    Harness.case ("catalog.rows-are-frozen", function ()
        Expect.equal (table.isfrozen (Catalog.entries :: any), true)

        for code, entry in Catalog.entries do
            Expect.equal (table.isfrozen (entry :: any), true)
            Expect.holds (table.isfrozen (entry.keys :: any), `{code} has a keys list to write to`)
        end
    end),

    --[[
        A line with every fact behind it has no brace left in it. That is the whole of what the
        composer promises about a record the library raised itself, since every raising site hands
        over the keys its own row declares.
    ]]
    Harness.case ("catalog.line-fills-every-key", function ()
        for code, entry in Catalog.entries do
            local said = Log.line (code, filled (entry))

            Expect.equal (string.match (said, HELD), nil)
            Expect.holds (#said > 0, `{code} composed nothing at all`)

            for _, key in entry.keys do
                Expect.holds (string.find (said, `<{key}>`, 1, true) ~= nil, `{code} lost {key}`)
            end
        end
    end),

    --[[
        A name with no fact behind it comes back in its braces rather than as a gap, so a record
        missing one still says which. The other two are checked alongside it, so a line that
        dropped every missing name would not pass on the one it happened to fill.
    ]]
    Harness.case ("catalog.line-keeps-a-missing-fact", function ()
        local said = Log.line (Catalog.TAG, { path = PATH })

        Expect.holds (string.find (said, PATH, 1, true) ~= nil, "the fact it had was not said")
        Expect.holds (string.find (said, "{expected}", 1, true) ~= nil, "the missing one vanished")
        Expect.holds (string.find (said, "{got}", 1, true) ~= nil, "the other missing one vanished")
    end),

    --[[
        One code composes one sentence, however many times it is asked. A site that reached its
        diagnosis without raising owes the caller the same words as one that raised, and composing
        it a second way is how one code comes to read two ways.
    ]]
    Harness.case ("catalog.line-is-one-sentence", function ()
        local facts = { path = PATH, expected = WANTED, got = GOT }

        local first = Log.line (Catalog.TAG, facts)
        local second = Log.line (Catalog.TAG, facts)
        Expect.equal (first, second)

        Expect.holds (string.find (first, PATH, 1, true) ~= nil, "the path is not in the line")
        Expect.holds (string.find (first, WANTED, 1, true) ~= nil, "what it wanted is not")
        Expect.holds (string.find (first, GOT, 1, true) ~= nil, "what it got is not")
    end),

    --[[
        The shape violations the wire can carry say the same three things, because there are only
        three to say: the field, what the schema wanted there, and what the bytes had instead. A
        validate carries the caller's own words in place of the expectation.
    ]]
    Harness.case ("catalog.shape-rows-say-three-things", function ()
        local three = setOf ({ "path", "expected", "got" })

        for _, code in { Catalog.TAG, Catalog.COUNT, Catalog.VARINT, Catalog.PAD } do
            local declared = setOf (Catalog.entries[code].keys)
            for name in three do
                Expect.holds (declared[name] == true, `{code} does not say {name}`)
            end
        end

        local turned = setOf (Catalog.entries[Catalog.VALIDATE].keys)
        Expect.equal (turned.path, true)
        Expect.equal (turned.reason, true)
        Expect.equal (turned.expected, nil)
    end),

    --[[
        The frame rows, held to declaring no path under any of the names a field row uses. One
        that grew one would point a reader at a field the failure was never about.
    ]]
    Harness.case ("catalog.frame-rows-name-no-path", function ()
        for _, code in
            { Catalog.BOUNDS, Catalog.DEFID, Catalog.HELLO, Catalog.UNREADY, Catalog.MISMATCH }
        do
            local declared = setOf (Catalog.entries[code].keys)
            Expect.equal (declared.path, nil)
        end
    end),

    --[[
        The two rows whose whole fact is a settled phrase. Each covers several ways of failing and
        the raising site says which by handing over one of its own constants, so what reaches a
        record is a phrase that was written once rather than a line composed on a decode.
    ]]
    Harness.case ("catalog.settled-phrases", function ()
        for _, code in { Catalog.SECTION, Catalog.BOUNDS } do
            local entry = Catalog.entries[code]

            Expect.equal (#entry.keys, 1)
            Expect.equal (entry.keys[1], "said")
        end
    end),
}
