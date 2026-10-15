--!strict
--!optimize 2
-- Bytes and back: what a codec writes, what it reads, and how wide it ever gets.

local Codecs = require("@src/codec")

local Expect = require("@test/harness/Expect")
local Generate = require("@test/harness/Generate")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")
local Turns = require("@test/harness/Turns")

local DEPTH = Generate.DEEP

-- Bounds that put a count in two, three and four bytes, and how full a list at each one is filled.
local COUNTS = table.freeze({
    { max = 256, bytes = 2, carried = 256 },
    { max = 65536, bytes = 3, carried = 65536 },
    { max = 16777216, bytes = 4, carried = 0 },
})

-- The element shapes a wide count sits in front of, written by different hands.
local ELEMENTS = table.freeze({
    {
        what = "bool",
        of = Codecs.bool(),
        bits = 1,
        rows = 3,
        value = function(at: number): any
            return at % 2 == 1
        end,
    },
    {
        what = "f32",
        of = Codecs.f32(),
        bits = 32,
        rows = 2,
        value = function(at: number): any
            return at % 2
        end,
    },
    {
        what = "str",
        of = Codecs.str(1, 1),
        bits = 8,
        rows = 2,
        value = function(at: number): any
            return string.char(65 + at % 26)
        end,
    },
})

-- Two families of quaternion, each walked across the surface where its two largest components
-- change places, and how the crossing is swept.
local CROSSINGS = table.freeze({ { 0.2, 0.3, 0.6, 0.9 }, { -0.27, 0.18, 0.62, 0.66 } })
local WALKED = 60
local SWING = 0.4
local GRIDS = table.freeze({ 1, 4, 10 })

-- A decoded value against the one encoded, at the distance the kind itself declares.
local function carried(shape: Generate.Shape, want: any, got: any)
    local slack = Generate.slack(shape)
    if slack == nil then return end
    if slack == 0 then
        Expect.equal(got, want)
    else
        Expect.near(got, want, slack)
    end
end

-- One value through a codec and back, and the read value re-encoded to the same bytes.
local function carries(shape: Generate.Shape, value: any, what: string)
    local of = Turns.built(Generate.codec(shape))
    local bytes, size = Turns.wrote(of, value)
    local got = Turns.read(of, bytes, size)
    carried(shape, value, got)

    local again, twice = Turns.wrote(of, got)
    if buffer.readstring(again, 0, twice) == buffer.readstring(bytes, 0, size) then return end
    Expect.holds(twice == size, `{what} re-encoded to {twice} bytes and not the {size} it read`)
    Expect.holds(false, `{what} re-encoded {size} different bytes`)
end

-- One rotation encoded, read back and encoded again, writing the same bytes both times.
local function stable(of: any, turn: CFrame, slack: number)
    local bytes, size = Turns.wrote(of, turn)
    local got = Turns.read(of, bytes, size)
    local again, twice = Turns.wrote(of, got)
    Expect.equal(twice, size)
    Expect.equal(buffer.readstring(again, 0, twice), buffer.readstring(bytes, 0, size))
    Expect.near(got, turn, slack)
end

return {
    -- A count wider than one byte, which nothing else in the tree reaches.
    Harness.case("wire.wide-counts", function()
        for _, elem in ELEMENTS do
            for index = 1, elem.rows do
                local bound = COUNTS[index]
                local of = Turns.built(Codecs.array(elem.of :: any, 0, bound.max))
                local empty, none = Turns.wrote(of, {})
                Expect.holds(none == bound.bytes, `{elem.what} spent {none} on an empty count`)
                Expect.equal(#Turns.read(of, empty, none), 0)

                local reach = bound.carried
                if reach == 0 then continue end
                local held = table.create(reach) :: { any }
                for at = 1, reach do
                    held[at] = elem.value(at)
                end
                local bytes, size = Turns.wrote(of, held)
                Expect.equal(size, bound.bytes + reach * elem.bits // 8)
                local got = Turns.read(of, bytes, size)
                Expect.equal(#got, reach)
                for _, at in { 1, reach // 2, reach } do
                    Expect.holds(got[at] == held[at], `{elem.what} lost the element at {at}`)
                end
            end
        end
    end),

    -- Every kind at every size it can be asked for, the draw stratified so the kinds with the most
    -- to get wrong get an equal share of the budget.
    Harness.property("wire.matrix", "kinds", function(rng: Rng.Rng)
        local at = rng:pick(Generate.KINDS)
        local size = rng:pick(Generate.SIZED)
        local shape = Generate.among(rng, { at }, DEPTH)
        carries(shape, Generate.sized(shape, size, rng), `{at} {size}`)
    end),

    -- Any codec at all over a value drawn from the parameters that built it: a map of tagged
    -- variants of optionals, four deep, with the counts wherever the tape put them.
    Harness.property("wire.identity", "encode", function(rng: Rng.Rng)
        local shape = Generate.shape(rng, DEPTH)
        carries(shape, Generate.value(shape, rng), shape.at)
    end),

    -- The bound is exact both ways round: no value the codec accepts encodes past it, and some
    -- value it accepts reaches it.
    Harness.property("wire.max-bytes", "kinds", function(rng: Rng.Rng)
        local shape = Generate.shape(rng, DEPTH)
        local of = Turns.built(Generate.codec(shape))
        local _, drawn = Turns.wrote(of, Generate.value(shape, rng))
        Expect.holds(drawn <= of.maxBytes, `{shape.at} wrote {drawn} of {of.maxBytes} bytes`)

        local reached = 0
        for _, candidate in Generate.widest(shape) do
            local _, size = Turns.wrote(of, candidate)
            reached = math.max(reached, size)
        end
        Expect.holds(
            reached == of.maxBytes,
            `{shape.at} promises {of.maxBytes} and reaches {reached}`
        )
    end),

    -- The curated shapes a draw will not reach, each out and back at its widest.
    Harness.case("wire.adversaries", function()
        for _, one in Generate.adversaries() do
            for _, candidate in Generate.widest(one.shape) do
                carries(one.shape, candidate, one.name)
            end
        end
    end),

    -- Rotations whose largest component is not settled by rounding, encoded twice. The scheme
    -- drops one component and names it, so the bytes must not take turns between two spellings.
    Harness.case("wire.quat-one-spelling", function()
        for _, apart in GRIDS do
            local of = Turns.built(Codecs.rotation.quat(apart))
            local slack = 2 * math.sin(math.rad(apart) / 2)
            for _, held in CROSSINGS do
                for step = 0, WALKED do
                    local moved = SWING * (step / WALKED - 0.5)
                    local x, y, z, w = held[1], held[2], held[3] + moved, held[4] - moved
                    local length = math.sqrt(x * x + y * y + z * z + w * w)
                    local turn = CFrame.new(0, 0, 0, x / length, y / length, z / length, w / length)
                    stable(of, turn, slack)
                end
            end
        end
    end),
}
