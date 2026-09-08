--!strict
--!optimize 2
-- The pinned artifacts, against what the implementation answers today.

local Base = require("@src/codec/Base")
local Serial = require("@src/shape/Serial")
local Shape = require("@src/shape")
local Wide = require("@src/kernel/Wide")

local Golden = require("@fixtures/Golden")
local Scenarios = require("@fixtures/Scenarios")
local Schemas = require("@fixtures/Schemas")
local Stage = require("@fixtures/Stage")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

-- Every key a pinned table holds and every key the fixtures answer for, held to being the same
-- set before any value is compared.
local function paired(pinned: { [string]: any }, made: { [string]: any }, what: string)
    for key in pinned do
        Expect.holds(made[key] ~= nil, `the {what} corpus pins {key}, which no fixture answers for`)
    end
    for key in made do
        Expect.holds(pinned[key] ~= nil, `{key} answers a {what} that nothing pins`)
    end
end

local function described(codec: any): string
    return Serial.describe({ cell = Base.cell(codec) })
end

-- A dump as one text, so a mismatch reads as the frames it is rather than as a table.
local function joined(of: { string }): string
    return table.concat(of, "\n")
end

return {
    -- The text every fixture schema writes, which two machines compare before either spends a
    -- byte. Most of what moves it is invisible from outside: a walk's order, how a decimal is
    -- spelled, whether a name is quoted.
    Harness.case("det.golden-descriptors", function()
        local made = {}
        for _, held in Schemas.all do
            made[held.name] = described(held.codec)
        end
        paired(Golden.descriptors, made, "descriptor")
        for name, text in Golden.descriptors do
            if made[name] ~= nil then Expect.equal(made[name], text) end
        end
    end),

    -- Each of those texts folded, against the number pinned for it.
    Harness.case("det.golden-hashes", function()
        local made = {}
        for _, held in Schemas.all do
            made[held.name] = Wide.toHex(Serial.hash(described(held.codec)))
        end
        paired(Golden.hashes, made, "hash")
        for name, digits in Golden.hashes do
            if made[name] ~= nil then Expect.equal(made[name], digits) end
        end
    end),

    -- What every fixture case costs on the wire. A compaction that quietly stops compacting costs
    -- bytes on every fire, and nothing else would say so because those bytes round trip perfectly.
    Harness.case("det.golden-sizes", function()
        local made = {}
        for _, held in Schemas.all do
            local of = Shape.build(held.codec, held.name)
            for _, one in held.cases do
                local out = buffer.create(of.maxBytes)
                made[`{held.name}.{one.name}`] = of.write(out, 0, one.value)
            end
        end
        paired(Golden.sizes, made, "size")
        for name, bytes in Golden.sizes do
            if made[name] ~= nil then Expect.equal(made[name], bytes) end
        end
    end),

    -- Every scenario driven and its frames held to the bytes pinned for them. A change to how a
    -- value packs is one both machines make together, so every round trip still holds: it breaks
    -- the client on the old build alone, which no single-build suite reaches.
    Harness.case("det.golden-frames", function()
        local made: { [string]: { string } } = {}
        for _, of in Scenarios.all do
            local run = Stage.opened(of)
            for _, step in of.steps do
                Stage.performed(run, step)
                if step.act == "flush" then made[`{of.name}.{step.mark}`] = Stage.dump(run) end
            end
        end
        paired(Golden.frames, made, "frame")
        for name, lines in Golden.frames do
            local mine = made[name]
            if mine ~= nil then Expect.equal(joined(mine), joined(lines)) end
        end
    end),
}
