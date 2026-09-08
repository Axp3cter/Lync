--!strict
--!optimize 2
-- The diagnosis rows alone: what each says, what it declares, and that the two agree.

local Catalog = require("@src/kernel/Catalog")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

-- The scope every code is under, and the case a name is written in.
local SCOPE = "drop"
local SPELLED = "^%l[%l-]*$"

local function braced(entry: Catalog.Entry): { string }
    local out = {}
    for name in string.gmatch(entry.template, Catalog.HELD) do
        table.insert(out, name)
    end
    return out
end

local function setOf(names: { string }): { [string]: boolean }
    local out: { [string]: boolean } = {}
    for _, name in names do
        out[name] = true
    end
    return out
end

return {
    -- Every code is a scope and a lowercase name, the greppable id a caller branches on.
    Harness.case("catalog.codes-are-scoped", function()
        local counted = 0
        for code in Catalog.entries do
            counted += 1
            local scope, name = string.match(code, "^(%w+)%.(.*)$")
            Expect.equal(scope, SCOPE)
            Expect.holds(name ~= nil and string.match(name, SPELLED) ~= nil, `{code} is spelled`)
        end
        Expect.holds(counted > 0, "the catalogue holds no rows at all")
    end),

    -- The keys a row declares are exactly the names its template holds in braces.
    Harness.case("catalog.keys-match-templates", function()
        for code, entry in Catalog.entries do
            Expect.equal(entry.keys, braced(entry))
            Expect.holds(#entry.template > 0, `{code} has an empty template`)
        end
    end),

    -- Every named constant reaches a row, and every row has a constant.
    Harness.case("catalog.constants-cover-the-rows", function()
        local named = 0
        for key, value in Catalog :: { [string]: unknown } do
            if typeof(value) == "string" and string.match(value, `^{SCOPE}%.`) ~= nil then
                named += 1
                Expect.holds(Catalog.entries[value :: Catalog.Code] ~= nil, `{key} has no row`)
            end
        end

        local rows = 0
        for _ in Catalog.entries do
            rows += 1
        end
        Expect.equal(named, rows)
    end),

    Harness.case("catalog.rows-are-frozen", function()
        Expect.equal(table.isfrozen(Catalog.entries :: any), true)
        for code, entry in Catalog.entries do
            Expect.equal(table.isfrozen(entry :: any), true)
            Expect.holds(table.isfrozen(entry.keys :: any), `{code} has a keys list to write to`)
        end
    end),

    -- The shape violations say the same three things, and a validate carries the caller's reason.
    Harness.case("catalog.shape-rows-say-three-things", function()
        local three = setOf({ "path", "expected", "got" })
        for _, code in { Catalog.TAG, Catalog.COUNT, Catalog.VARINT, Catalog.PAD } do
            local declared = setOf(Catalog.entries[code].keys)
            for name in three do
                Expect.holds(declared[name] == true, `{code} does not say {name}`)
            end
        end

        local turned = setOf(Catalog.entries[Catalog.VALIDATE].keys)
        Expect.equal(turned.path, true)
        Expect.equal(turned.reason, true)
        Expect.equal(turned.expected, nil)
    end),

    Harness.case("catalog.frame-rows-name-no-path", function()
        for _, code in
            { Catalog.BOUNDS, Catalog.DEFID, Catalog.HELLO, Catalog.UNREADY, Catalog.MISMATCH }
        do
            Expect.equal(setOf(Catalog.entries[code].keys).path, nil)
        end
    end),

    -- The two rows whose whole fact is a settled phrase the raising site hands over.
    Harness.case("catalog.settled-phrases", function()
        for _, code in { Catalog.SECTION, Catalog.BOUNDS } do
            Expect.equal(Catalog.entries[code].keys, { "said" })
        end
    end),
}
