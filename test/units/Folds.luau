--!strict
--!optimize 2
--[[
    A value that comes apart by a computation, as the leaves it takes and the pair over them.
]]

local Base = require ("@src/codec/Base")
local Folds = require ("@src/shape/Folds")
local Lync = require ("@src")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

-- A precision an ordinary schema asks for, in degrees, and the angle it rounds a turn onto.
const COARSE = 5

-- Bounds a drawn component is laid inside, and the step it is quantized onto.
const LOW = -8
const HIGH = 8
const STEP = 0.5

-- The reach and step of a bounded vector, which is a radius and how finely it is cut.
const REACH = 16
const CUT = 0.25

-- Where in a run a case writes its leaves from, which is never the front.
const FROM = 4

--[[
    How far a value may sit from the one it went in as. Nothing here is asked to survive a rounding,
    so what this covers is what the arithmetic loses and not what a grid does.
]]
const NEARLY = 1e-6

-- A palette, and a colour that is no member of it.
const PALETTE = table.freeze ({ Color3.new (1, 0, 0), Color3.new (0, 1, 0), Color3.new (0, 0, 1) })
const OUTSIDE = Color3.new (0.5, 0.5, 0.5)

-- Types ---------------------------------------------------------------

type Fold = Folds.Fold

-- Private -------------------------------------------------------------

-- A declaration as the fold it is, which every case here begins with.
local function fold (of: any): Fold
    local held = Folds.fold (Base.cell (of))
    Expect.holds (held ~= nil, "a declaration that should fold does not")
    return held :: Fold
end

-- One value down into a run and back up, written from a place that is not the front.
local function through (held: Fold, value: any): any
    local run = {}
    Expect.equal (held.pull (value, run, FROM), true)
    return held.push (run, FROM)
end

-- A fold turning a value away, rather than raising where it would be indexed.
local function refuses (of: Fold, value: any) Expect.equal (of.pull (value, {}, FROM), false) end

--[[
    Everything a case needs of a vector, worked out from its three components.

    The library asks a datatype for its components and nothing else, so a unit over the folds asks
    for no more than that either: what a check needs of the engine is what the fold needs.
]]
local function apart (left: Vector3, right: Vector3): number
    local x, y, z = left.X - right.X, left.Y - right.Y, left.Z - right.Z
    return math.sqrt (x * x + y * y + z * z)
end

local function along (left: Vector3, right: Vector3): number
    return left.X * right.X + left.Y * right.Y + left.Z * right.Z
end

-- The angle between two directions in degrees, which is what a precision is read against.
local function opened (left: Vector3, right: Vector3): number
    local reach = left.Magnitude * right.Magnitude
    return math.deg (math.acos (math.clamp (along (left, right) / reach, -1, 1)))
end

--[[
    How far apart two frames turn, in degrees, read off the nine components each carries.

    The trace of one turn against the other is one plus twice the cosine of the angle between them,
    which needs no inverse and no multiplication of frames, neither of which the library asks for.
]]
local function turnedBy (left: CFrame, right: CFrame): number
    local ours = { select (4, left:GetComponents ()) }
    local theirs = { select (4, right:GetComponents ()) }

    local trace = 0
    for at = 1, 9 do
        trace += ours[at] * theirs[at]
    end
    return math.deg (math.acos (math.clamp ((trace - 1) / 2, -1, 1)))
end

-- Public --------------------------------------------------------------

return {
    --[[
        Which declarations come apart by a computation and which do not. A vector of floats and a
        colour of them are not folds, since every IEEE float is a byte field wherever it appears and
        what puts three of them side by side is a lowering rather than a fold.
    ]]
    Harness.case ("folds.which", function ()
        local folded = {
            Lync.vec2 (Lync.int (LOW, HIGH)),
            Lync.vec3 (Lync.int (LOW, HIGH)),
            Lync.vec3.unit (COARSE),
            Lync.vec3.bounded (REACH, CUT),
            Lync.rotation.none (),
            Lync.rotation.quat (COARSE),
            Lync.color3.rgb565 (),
            Lync.color3.palette (PALETTE),
        }

        for _, of in folded do
            Expect.holds (Folds.fold (Base.cell (of)) ~= nil, "a fold answered nothing")
        end

        local flat = {
            Lync.vec3 (),
            Lync.color3 (),
            Lync.cframe (Lync.vec3 (), Lync.rotation.quat (COARSE)),
            Lync.int (LOW, HIGH),
            Lync.struct ({ a = Lync.bool () }),
        }

        for _, of in flat do
            Expect.equal (Folds.fold (Base.cell (of)), nil)
        end
    end),

    --[[
        What the engine calls each of the four this file takes apart, held to what the engine
        answers for a value of each. The names are asked of the engine rather than of the value's
        shape, since a vector and a colour both carry three numbers.
    ]]
    Harness.case ("folds.engine-names", function ()
        Expect.equal (Folds.ENGINE.vec2, typeof (Vector2.new (0, 0)))
        Expect.equal (Folds.ENGINE.vec3, typeof (Vector3.new (0, 0, 0)))
        Expect.equal (Folds.ENGINE.color3, typeof (Color3.new (0, 0, 0)))
        Expect.equal (Folds.ENGINE.cframe, typeof (CFrame.identity))
    end),

    --[[
        A vector of quantized components, at both widths. Two leaves or three, one grid each, and
        what comes back is the value rounded onto the grid its components were cut on.
    ]]
    Harness.case ("folds.vectors", function ()
        local flat = fold (Lync.vec2 (Lync.quant (LOW, HIGH, STEP)))
        Expect.equal (#flat.leaves, 2)

        local was = Vector2.new (1.5, -2)
        local back = through (flat, was) :: Vector2
        Expect.near (back.X, was.X, NEARLY)
        Expect.near (back.Y, was.Y, NEARLY)

        local wide = fold (Lync.vec3 (Lync.quant (LOW, HIGH, STEP)))
        Expect.equal (#wide.leaves, 3)

        local held = Vector3.new (1.5, -2, 0)
        Expect.near (apart (through (wide, held) :: Vector3, held), 0, NEARLY)
    end),

    --[[
        A component the grid has no place for, and a value that is no vector at all. Both are turned
        away rather than raised on, because a raise from inside a fold comes out of an encode
        several frames under the declaration and names no field.
    ]]
    Harness.case ("folds.vectors-refuse", function ()
        local held = fold (Lync.vec3 (Lync.quant (LOW, HIGH, STEP)))

        refuses (held, Vector3.new (HIGH + 1, 0, 0))
        refuses (held, Vector3.new (0, 0, 0 / 0))
        refuses (held, Vector2.new (0, 0))
        refuses (held, CFrame.identity)
        refuses (held, 0)
    end),

    --[[
        A direction, which is two of a vector's three degrees of freedom. What comes back is a unit
        vector within the precision the parameter names, and the length it went in with is nowhere
        in the bytes.
    ]]
    Harness.case ("folds.unit", function ()
        local held = fold (Lync.vec3.unit (COARSE))
        Expect.equal (#held.leaves, 2)

        local was = Vector3.new (1, 2, 3)
        local back = through (held, was) :: Vector3

        Expect.near (back.Magnitude, 1, NEARLY)
        Expect.holds (opened (back, was) <= COARSE, "a direction came back past its precision")

        -- Any multiple of a direction is the same direction, which is what the fold divides out.
        Expect.near (apart (through (held, was * REACH) :: Vector3, back), 0, NEARLY)
        refuses (held, Vector2.new (0, 0))
    end),

    --[[
        The one form built over two grids, asked as three leaves and a round trip. Where it points
        and how far it reaches are cut on different grids, so the two are read against different
        margins: the direction against its precision and the length against its step.
    ]]
    Harness.case ("folds.bounded", function ()
        local held = fold (Lync.vec3.bounded (REACH, CUT))
        Expect.equal (#held.leaves, 3)

        local was = Vector3.new (3, -4, 12)
        local back = through (held, was) :: Vector3

        Expect.near (back.Magnitude, was.Magnitude, CUT)
        Expect.holds (opened (back, was) <= REACH, "a bounded vector came back pointing elsewhere")

        -- Past the radius is no place the grid holds, which is a refusal rather than a clamp.
        refuses (held, Vector3.new (REACH * 2, 0, 0))
    end),

    --[[
        A vector of no length, which points nowhere and has to be somewhere. The fold divides by the
        sum of the magnitudes and a zero divides by nothing, so the direction of one is the middle
        of the square, which multiplies back out to the zero it was.
    ]]
    Harness.case ("folds.bounded-zero", function ()
        local held = fold (Lync.vec3.bounded (REACH, CUT))
        local back = through (held, Vector3.new (0, 0, 0)) :: Vector3

        Expect.equal (back.Magnitude, 0)
    end),

    --[[
        Two vectors differing in direction alone, both under the step the grid can see, held to
        coming out as one set of bytes. Asked below the step rather than at zero, since zero is the
        case anybody would have written the branch for.
    ]]
    Harness.case ("folds.bounded-shortest", function ()
        local held = fold (Lync.vec3.bounded (REACH, CUT))
        local tiny = CUT / 8

        local one, two = {}, {}
        Expect.equal (held.pull (Vector3.new (tiny, 0, 0), one, FROM), true)
        Expect.equal (held.pull (Vector3.new (0, -tiny, 0), two, FROM), true)

        Expect.equal (table.concat (one, " "), table.concat (two, " "))
        Expect.equal ((held.push (one, FROM) :: Vector3).Magnitude, 0)
    end),

    --[[
        A fold of no leaves, which is a fold all the same. Both halves are asked of it, since a
        pair that took nothing and gave nothing back would satisfy a case reading only one of them,
        and what comes back has to be the one frame the declaration can mean.
    ]]
    Harness.case ("folds.rotation-none", function ()
        local held = fold (Lync.rotation.none ())

        Expect.equal (#held.leaves, 0)
        Expect.equal (held.pull (CFrame.identity, {}, FROM), true)
        Expect.equal (held.push ({}, FROM), CFrame.identity)
    end),

    --[[
        The three forms that carry a turn, each with the leaves its own mapping takes: one for an
        angle about a declared axis, two for a look direction, and four for a smallest three, which
        is the tag and the three components that travel.
    ]]
    Harness.case ("folds.rotation-leaves", function ()
        Expect.equal (#fold (Lync.rotation.axis (Vector3.new (0, 1, 0), COARSE)).leaves, 1)
        Expect.equal (#fold (Lync.rotation.direction (COARSE)).leaves, 2)
        Expect.equal (#fold (Lync.rotation.quat (COARSE)).leaves, 4)
    end),

    --[[
        A turn, out and back, and the position it never carried. What comes back sits at the
        origin whatever frame went in, which is what says a rotation codec carries no position.
    ]]
    Harness.case ("folds.rotation-quat", function ()
        local held = fold (Lync.rotation.quat (COARSE))

        local was = CFrame.fromAxisAngle (Vector3.new (1, 2, 3), 1.1) + Vector3.new (5, 6, 7)
        local back = through (held, was) :: CFrame

        Expect.near (back.Position.Magnitude, 0, NEARLY)
        Expect.holds (turnedBy (back, was) <= COARSE, "a turn came back past its precision")

        refuses (held, Vector3.new (0, 0, 0))
    end),

    --[[
        A packed colour, which spends sixteen bits on three channels: five, six and five, red first
        and least. Green takes the extra bit because that is the one an eye tells apart most finely,
        and the widths are the protocol's rather than this file's.
    ]]
    Harness.case ("folds.color-packed", function ()
        local held = fold (Lync.color3.rgb565 ())
        Expect.equal (#held.leaves, 3)

        local widths = {}
        for _, grid in held.leaves do
            table.insert (widths, grid.width)
        end
        Expect.equal (table.concat (widths, " "), "5 6 5")

        local was = Color3.new (1, 0.5, 0)
        local back = through (held, was) :: Color3

        Expect.near (back.R, was.R, NEARLY)
        Expect.near (back.G, was.G, 1 / 2 ^ 6)
        Expect.near (back.B, was.B, NEARLY)
        refuses (held, Vector3.new (0, 0, 0))
    end),

    --[[
        A palette, asked with the colours it holds and with one it does not, and then asked again
        with a colour rebuilt from another's components. The rebuilt one is what says the lookup is
        by component rather than by identity, which is a distinction only a fresh value shows.
    ]]
    Harness.case ("folds.color-palette", function ()
        local held = fold (Lync.color3.palette (PALETTE))
        Expect.equal (#held.leaves, 1)

        for _, one in PALETTE do
            local back = through (held, one) :: Color3
            Expect.equal (back, one)
        end

        -- Rebuilt rather than the same value, which is what says the lookup is by component.
        local same = Color3.new (PALETTE[2].R, PALETTE[2].G, PALETTE[2].B)
        Expect.equal (through (held, same), PALETTE[2])

        -- A colour the list does not hold, which a ranged int over a list already turns away.
        refuses (held, OUTSIDE)
    end),

    --[[
        Every fold writes exactly as many places as it has leaves, from wherever it was told to
        start. A field's leaves sit at its own place in the run rather than at the front, so a fold
        that assumed the front would write over the field before it.
    ]]
    Harness.case ("folds.fills-its-leaves", function ()
        local held = {
            { of = Lync.vec2 (Lync.int (LOW, HIGH)), value = Vector2.new (1, 2) },
            { of = Lync.vec3 (Lync.int (LOW, HIGH)), value = Vector3.new (1, 2, 3) },
            { of = Lync.vec3.unit (COARSE), value = Vector3.new (0, 1, 0) },
            { of = Lync.vec3.bounded (REACH, CUT), value = Vector3.new (1, 0, 0) },
            { of = Lync.rotation.quat (COARSE), value = CFrame.identity },
            { of = Lync.color3.rgb565 (), value = Color3.new (0, 0, 0) },
            { of = Lync.color3.palette (PALETTE), value = PALETTE[1] },
        }

        for _, one in held do
            local of = fold (one.of)
            local run = {}

            Expect.equal (of.pull (one.value, run, FROM), true)

            -- Counted rather than measured, since a run written from the fourth place has holes.
            local written = 0
            for _ in run do
                written += 1
            end
            Expect.equal (written, #of.leaves)

            for at = 1, FROM - 1 do
                Expect.equal (run[at], nil)
            end
            for at = FROM, FROM + #of.leaves - 1 do
                Expect.holds (run[at] ~= nil, `a leaf at {at} was left unwritten`)
            end
        end
    end),
}
