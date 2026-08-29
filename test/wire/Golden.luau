--!strict
--!optimize 2
-- The pinned artifacts, against what the implementation answers today.

local Base = require ("@src/codec/Base")
local Serial = require ("@src/shape/Serial")
local Shape = require ("@src/shape")
local Wide = require ("@src/kernel/Wide")

local Golden = require ("@fixtures/Golden")
local Scenarios = require ("@fixtures/Scenarios")
local Schemas = require ("@fixtures/Schemas")
local Stage = require ("@fixtures/Stage")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Private -------------------------------------------------------------

--[[
    Every key a pinned table holds and every key the fixtures answer for, held to being the same set
    before any value is compared.
]]
local function paired (pinned: { [string]: any }, made: { [string]: any }, what: string)
    for key in pinned do
        if made[key] ~= nil then continue end
        Expect.holds (false, `the {what} corpus pins {key}, which no fixture answers for`)
    end

    for key in made do
        if pinned[key] ~= nil then continue end
        Expect.holds (false, `{key} answers a {what} that nothing pins`)
    end
end

--[[
    A dump as one text, so a mismatch reads as the frames it is rather than as a table.

    The lines are joined on a newline because that is how a person reads a dump, and a difference
    anywhere in it is one difference rather than one per frame after the first.
]]
local function joined (of: { string }): string return table.concat (of, "\n") end

-- Public --------------------------------------------------------------

return {
    --[[
        The text every fixture schema writes, against the text it wrote when the corpus was made.
        The descriptor is what two machines compare before either spends a byte, and most of what
        moves it is invisible from outside: a walk's order, how a decimal is spelled, whether a name
        is quoted.
    ]]
    Harness.case ("det.golden-descriptors", function ()
        local made = {}
        for _, held in Schemas.all do
            made[held.name] = Serial.describe ({ cell = Base.cell (held.codec) })
        end

        paired (Golden.descriptors, made, "descriptor")
        for name, text in Golden.descriptors do
            if made[name] == nil then continue end
            Expect.equal (made[name], text)
        end
    end),

    -- Each of those texts folded, against the number pinned for it.
    Harness.case ("det.golden-hashes", function ()
        local made = {}
        for _, held in Schemas.all do
            local text = Serial.describe ({ cell = Base.cell (held.codec) })
            made[held.name] = Wide.text (Serial.hash (text))
        end

        paired (Golden.hashes, made, "hash")
        for name, digits in Golden.hashes do
            if made[name] == nil then continue end
            Expect.equal (made[name], digits)
        end
    end),

    --[[
        What every fixture case costs on the wire, which is the size contract in the one form that
        gates. A compaction that quietly stops compacting costs bytes on every fire of every place
        that ships it, and nothing else here would say so because those bytes round trip perfectly.
    ]]
    Harness.case ("det.golden-sizes", function ()
        local made = {}
        for _, held in Schemas.all do
            local of = Shape.build (held.codec, held.name)
            for _, one in held.cases do
                local out = buffer.create (of.maxBytes)
                made[`{held.name}.{one.name}`] = of.write (out, 0, one.value)
            end
        end

        paired (Golden.sizes, made, "size")
        for name, bytes in Golden.sizes do
            if made[name] == nil then continue end
            Expect.equal (made[name], bytes)
        end
    end),

    --[[
        Every scenario driven and its frames held to the bytes pinned for them. A change to how a
        value packs is one both machines make together, so both agree and every round trip holds:
        it breaks the client on the old build alone, which no single-build suite reaches.
        Grouped by recipient, since arrival order between two of them is promised to nobody.
    ]]
    Harness.case ("det.golden-frames", function ()
        local made: { [string]: { string } } = {}
        for _, of in Scenarios.all do
            local run = Stage.opened (of)
            for _, step in of.steps do
                Stage.performed (run, step)
                if step.act ~= "flush" then continue end

                made[`{of.name}.{step.mark}`] = Stage.dump (run)
            end
        end

        paired (Golden.frames, made, "frame")
        for name, lines in Golden.frames do
            local mine = made[name]
            if mine == nil then continue end

            Expect.equal (joined (mine), joined (lines))
        end
    end),
}
