--!strict
--!optimize 2
-- A value that comes apart by a computation, as the leaves it takes and the pair over them.

local Base = require("@src/codec/Base")
local Codecs = require("@src/codec")
local Folds = require("@src/shape/Folds")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

-- A precision an ordinary schema asks for, in degrees.
local COARSE = 5

local LOW = -8
local HIGH = 8
local STEP = 0.5
local REACH = 16

-- Where in a run a case writes its leaves from, which is never the front.
local FROM = 4

-- What the arithmetic loses, not what a grid does.
local NEARLY = 1e-6

type Fold = Folds.Fold

local function fold(of: any): Fold
    local held = Folds.fold(Base.cell(of))
    Expect.holds(held ~= nil, "a declaration that should fold does not")
    return held :: Fold
end

-- One value down into a run and back up, written from a place that is not the front.
local function through(held: Fold, value: any): any
    local run = {}
    Expect.equal(held.pull(value, run, FROM), true)
    return held.push(run, FROM)
end

local function refuses(of: Fold, value: any)
    Expect.equal(of.pull(value, {}, FROM), false)
end

local function apart(left: Vector3, right: Vector3): number
    local x, y, z = left.X - right.X, left.Y - right.Y, left.Z - right.Z
    return math.sqrt(x * x + y * y + z * z)
end

-- The angle between two directions in degrees, worked from components alone.
local function opened(left: Vector3, right: Vector3): number
    local dot = left.X * right.X + left.Y * right.Y + left.Z * right.Z
    local reach = left.Magnitude * right.Magnitude
    return math.deg(math.acos(math.clamp(dot / reach, -1, 1)))
end

-- How far apart two frames turn, in degrees: the trace of one against the other is one plus twice
-- the cosine of the angle between them.
local function turnedBy(left: CFrame, right: CFrame): number
    local ours = { select(4, left:GetComponents()) }
    local theirs = { select(4, right:GetComponents()) }
    local trace = 0
    for at = 1, 9 do
        trace += ours[at] * theirs[at]
    end
    return math.deg(math.acos(math.clamp((trace - 1) / 2, -1, 1)))
end

return {
    -- A vector or colour of floats is not a fold: a float is a byte field wherever it appears.
    Harness.case("folds.which", function()
        for _, of in
            {
                Codecs.vec2(Codecs.int(LOW, HIGH)),
                Codecs.vec3(Codecs.int(LOW, HIGH)),
                Codecs.vec3.unit(COARSE),
                Codecs.rotation.none(),
                Codecs.rotation.quat(COARSE),
                Codecs.color3.rgb565(),
            }
        do
            Expect.holds(Folds.fold(Base.cell(of)) ~= nil, "a fold answered nothing")
        end
        for _, of in
            {
                Codecs.vec3(),
                Codecs.color3(),
                Codecs.cframe(Codecs.vec3(), Codecs.rotation.quat(COARSE)),
                Codecs.int(LOW, HIGH),
                Codecs.struct({ a = Codecs.bool() }),
                Codecs.vec3(Codecs.f32()),
            }
        do
            Expect.equal(Folds.fold(Base.cell(of)), nil)
        end
    end),

    -- The engine names are asked of the engine, since a vector and a colour both carry three
    -- numbers.
    Harness.case("folds.engine-names", function()
        Expect.equal(Folds.ENGINE.vec2, typeof(Vector2.new(0, 0)))
        Expect.equal(Folds.ENGINE.vec3, typeof(Vector3.new(0, 0, 0)))
        Expect.equal(Folds.ENGINE.color3, typeof(Color3.new(0, 0, 0)))
        Expect.equal(Folds.ENGINE.cframe, typeof(CFrame.identity))
    end),

    -- Two leaves or three, one grid each, and the value comes back rounded onto that grid.
    Harness.case("folds.vectors", function()
        local flat = fold(Codecs.vec2(Codecs.quant(LOW, HIGH, STEP)))
        Expect.equal(#flat.leaves, 2)
        local was = Vector2.new(1.5, -2)
        local back = through(flat, was) :: Vector2
        Expect.near(back.X, was.X, NEARLY)
        Expect.near(back.Y, was.Y, NEARLY)

        local wide = fold(Codecs.vec3(Codecs.quant(LOW, HIGH, STEP)))
        Expect.equal(#wide.leaves, 3)
        local held = Vector3.new(1.5, -2, 0)
        Expect.near(apart(through(wide, held) :: Vector3, held), 0, NEARLY)
    end),

    -- A component off the grid and a value that is no vector are turned away, never raised on.
    Harness.case("folds.vectors-refuse", function()
        local held = fold(Codecs.vec3(Codecs.quant(LOW, HIGH, STEP)))
        refuses(held, Vector3.new(HIGH + 1, 0, 0))
        refuses(held, Vector3.new(0, 0, 0 / 0))
        refuses(held, Vector2.new(0, 0))
        refuses(held, CFrame.identity)
        refuses(held, 0)
    end),

    -- A direction comes back as a unit vector within its precision, its length not in the bytes.
    Harness.case("folds.unit", function()
        local held = fold(Codecs.vec3.unit(COARSE))
        Expect.equal(#held.leaves, 2)

        local was = Vector3.new(1, 2, 3)
        local back = through(held, was) :: Vector3
        Expect.near(back.Magnitude, 1, NEARLY)
        Expect.holds(opened(back, was) <= COARSE, "a direction came back past its precision")
        Expect.near(apart(through(held, was * REACH) :: Vector3, back), 0, NEARLY)
        refuses(held, Vector2.new(0, 0))
        refuses(held, Vector3.new(0, 0, 0))
    end),

    -- A fold of no leaves is a fold all the same, and answers the one frame it can mean.
    Harness.case("folds.rotation-none", function()
        local held = fold(Codecs.rotation.none())
        Expect.equal(#held.leaves, 0)
        Expect.equal(held.pull(CFrame.identity, {}, FROM), true)
        Expect.equal(held.push({}, FROM), CFrame.identity)
    end),

    -- A turn out and back at the origin whatever frame went in: a rotation carries no position.
    Harness.case("folds.rotation-quat", function()
        local held = fold(Codecs.rotation.quat(COARSE))
        Expect.equal(#held.leaves, 4)
        Expect.equal(held.leaves[1].span, 3)

        local was = CFrame.fromAxisAngle(Vector3.new(1, 2, 3), 1.1) + Vector3.new(5, 6, 7)
        local back = through(held, was) :: CFrame
        Expect.near(back.Position.Magnitude, 0, NEARLY)
        Expect.holds(turnedBy(back, was) <= COARSE, "a turn came back past its precision")
        refuses(held, Vector3.new(0, 0, 0))

        -- A frame whose turn is no number lands on no grid, and is refused rather than written
        -- as whatever the leaves held before.
        refuses(held, CFrame.new(0, 0, 0, 0 / 0, 0, 0, 1))
    end),

    -- Five, six and five bits, red first, green taking the extra bit an eye tells apart finest.
    Harness.case("folds.color-packed", function()
        local held = fold(Codecs.color3.rgb565())
        Expect.equal(#held.leaves, 3)

        local widths = {}
        for _, grid in held.leaves do
            table.insert(widths, grid.width)
        end
        Expect.equal(table.concat(widths, " "), "5 6 5")

        local was = Color3.new(1, 0.5, 0)
        local back = through(held, was) :: Color3
        Expect.near(back.R, was.R, NEARLY)
        Expect.near(back.G, was.G, 1 / 2 ^ 6)
        Expect.near(back.B, was.B, NEARLY)
        refuses(held, Vector3.new(0, 0, 0))
    end),

    -- Every fold writes exactly as many places as it has leaves, from wherever it was told to
    -- start.
    Harness.case("folds.fills-its-leaves", function()
        for _, one in
            {
                { of = Codecs.vec2(Codecs.int(LOW, HIGH)), value = Vector2.new(1, 2) },
                { of = Codecs.vec3(Codecs.int(LOW, HIGH)), value = Vector3.new(1, 2, 3) },
                { of = Codecs.vec3.unit(COARSE), value = Vector3.new(0, 1, 0) },
                { of = Codecs.rotation.quat(COARSE), value = CFrame.identity },
                { of = Codecs.color3.rgb565(), value = Color3.new(0, 0, 0) },
            }
        do
            local of = fold(one.of)
            local run = {}
            Expect.equal(of.pull(one.value, run, FROM), true)

            local written = 0
            for _ in run do
                written += 1
            end
            Expect.equal(written, #of.leaves)
            for at = 1, FROM - 1 do
                Expect.equal(run[at], nil)
            end
            for at = FROM, FROM + #of.leaves - 1 do
                Expect.holds(run[at] ~= nil, `a leaf at {at} was left unwritten`)
            end
        end
    end),
}
