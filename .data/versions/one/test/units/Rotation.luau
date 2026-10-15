--!strict
--!optimize 2
-- The orientation mappings alone: a direction as a pair on a square, a turn as three of its four.

local Grid = require("@src/shape/Grid")
local Protocol = require("@src/wire/Protocol")
local Rotation = require("@src/shape/Rotation")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")

local QUAT_X = Protocol.QUAT_X
local QUAT_Y = Protocol.QUAT_Y
local QUAT_Z = Protocol.QUAT_Z
local QUAT_W = Protocol.QUAT_W
local BOUND = Protocol.QUAT_BOUND

-- Precisions in degrees, coarsest first. Ninety leaves a square three points a side and is where
-- every rounding is widest. Half a degree is where a search that scores badly still looks correct.
local DEGREES = table.freeze({ 90, 45, 10, 5, 1, 0.5 })

-- Every number here comes off a root and a normalize, so an exact answer arrives a part in
-- 2^52 out.
local NEARLY = 1e-9

-- The same margin for an angle read through an arc cosine, in degrees.
local HAIR = 1e-4

local TRIES = 64

type Turn = { x: number, y: number, z: number, w: number }

local function turn(x: number, y: number, z: number, w: number): Turn
    local length = math.sqrt(x * x + y * y + z * z + w * w)
    return { x = x / length, y = y / length, z = z / length, w = w / length }
end

-- The twelve components a frame is read with, for a unit quaternion and no position.
local function matrix(of: Turn)
    local x, y, z, w = of.x, of.y, of.z, of.w
    return 0,
        0,
        0,
        1 - 2 * (y * y + z * z),
        2 * (x * y - z * w),
        2 * (x * z + y * w),
        2 * (x * y + z * w),
        1 - 2 * (x * x + z * z),
        2 * (y * z - x * w),
        2 * (x * z - y * w),
        2 * (y * z + x * w),
        1 - 2 * (x * x + y * y)
end

-- A rotation drawn evenly over every rotation there is, by rejecting the corners of the 4-cube.
local function drawn(rng: Rng.Rng): Turn
    for _ = 1, TRIES do
        local x, y, z, w =
            rng:number(-1, 1), rng:number(-1, 1), rng:number(-1, 1), rng:number(-1, 1)
        local held = x * x + y * y + z * z + w * w
        if held > NEARLY and held <= 1 then return turn(x, y, z, w) end
    end
    return turn(0, 0, 0, 1)
end

-- A direction drawn evenly over the sphere: a drawn rotation's own third column negated.
local function pointed(rng: Rng.Rng): (number, number, number)
    local of = drawn(rng)
    local x, y, z, w = of.x, of.y, of.z, of.w
    return -2 * (x * z + y * w), -2 * (y * z - x * w), -(1 - 2 * (x * x + y * y))
end

-- How far apart two rotations are in degrees, which a quaternion and its negation are none of.
local function between(left: Turn, right: Turn): number
    local dot = left.x * right.x + left.y * right.y + left.z * right.z + left.w * right.w
    return math.deg(2 * math.acos(math.min(1, math.abs(dot))))
end

-- The three a tag sends, taken off a turn the way the mapping takes them.
local function travelling(tag: number, of: Turn): (number, number, number)
    local x, y, z, w = of.x, of.y, of.z, of.w
    local named = if tag == QUAT_X
        then x
        elseif tag == QUAT_Y then y
        elseif tag == QUAT_Z then z
        else w
    if named < 0 then
        x, y, z, w = -x, -y, -z, -w
    end
    if tag == QUAT_X then return y, z, w end
    if tag == QUAT_Y then return x, z, w end
    if tag == QUAT_Z then return x, y, w end
    return x, y, z
end

local function spelled(
    mapping: Rotation.Smallest,
    tag: number,
    a: number,
    b: number,
    c: number
): Turn
    local x, y, z, w = mapping.whole(tag, a, b, c)
    return { x = x, y = y, z = z, w = w }
end

local function away(ax: number, ay: number, az: number, bx: number, by: number, bz: number): number
    return math.deg(math.acos(math.clamp(ax * bx + ay * by + az * bz, -1, 1)))
end

-- The turns of a cube whose every component is a whole number or the bound itself.
local function square(): { Turn }
    local out = { turn(0, 0, 0, 1) }
    for _, axis in { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } } do
        local ax, ay, az = axis[1], axis[2], axis[3]
        table.insert(out, turn(ax, ay, az, 0))
        table.insert(out, turn(ax * BOUND, ay * BOUND, az * BOUND, BOUND))
        table.insert(out, turn(-ax * BOUND, -ay * BOUND, -az * BOUND, BOUND))
    end
    return out
end

return {
    -- The six axis directions are corners of the coarsest square, so nothing rounds.
    Harness.case("rotation.octahedral-poles", function()
        local mapping = Rotation.octahedral(Grid.plane(DEGREES[1]))
        for _, pole in
            { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
        do
            local x, y, z = pole[1], pole[2], pole[3]
            local u, v = mapping.plane(x, y, z)
            Expect.holds(u ~= nil and v ~= nil, `({x}, {y}, {z}) reached no point on the square`)
            local ax, ay, az = mapping.sphere(u :: number, v :: number)
            Expect.near(away(ax, ay, az, x, y, z), 0, HAIR)
        end
    end),

    -- A point read back and written again answers the first writing, an edge point's second name
    -- included.
    Harness.case("rotation.octahedral-idempotent", function()
        local grid = Grid.plane(DEGREES[2])
        local mapping = Rotation.octahedral(grid)
        for u = 0, grid.span do
            for v = 0, grid.span do
                local ax, ay, az = mapping.sphere(u, v)
                local firstU, firstV = mapping.plane(ax, ay, az)
                Expect.holds(firstU ~= nil, `({u}, {v}) read back as no direction at all`)

                local bx, by, bz = mapping.sphere(firstU :: number, firstV :: number)
                Expect.near(away(ax, ay, az, bx, by, bz), 0, HAIR)
                local againU, againV = mapping.plane(bx, by, bz)
                Expect.equal(againU, firstU)
                Expect.equal(againV, firstV)
            end
        end
    end),

    -- The near half fills the diamond the two coordinates sum to one inside, the rest is the fold.
    Harness.case("rotation.octahedral-fold", function()
        local grid = Grid.plane(DEGREES[2])
        local mapping = Rotation.octahedral(grid)
        for u = 0, grid.span do
            for v = 0, grid.span do
                local reach = math.abs(grid.fromIndex(u)) + math.abs(grid.fromIndex(v))
                local _, _, z = mapping.sphere(u, v)
                Expect.holds((z < 0) == (reach > 1), `({u}, {v}) sits {reach} out and points {z}`)
            end
        end
    end),

    -- The mapping divides by the sum of the magnitudes, so any multiple of a direction is the same
    -- bytes and no square root is spent.
    Harness.property("rotation.octahedral-scale-free", "leaves", function(rng: Rng.Rng)
        local mapping = Rotation.octahedral(Grid.plane(rng:pick(DEGREES)))
        local x, y, z = pointed(rng)
        local u, v = mapping.plane(x, y, z)
        Expect.holds(u ~= nil, "a drawn direction reached no point on the square")

        local scale = rng:number(NEARLY, 1000)
        local scaledU, scaledV = mapping.plane(x * scale, y * scale, z * scale)
        Expect.equal(scaledU, u)
        Expect.equal(scaledV, v)
    end),

    -- A direction written at p degrees comes back within p degrees of itself.
    Harness.property("rotation.octahedral-precision", "leaves", function(rng: Rng.Rng)
        local degrees = rng:pick(DEGREES)
        local mapping = Rotation.octahedral(Grid.plane(degrees))
        local x, y, z = pointed(rng)
        local u, v = mapping.plane(x, y, z)
        Expect.holds(u ~= nil, "a drawn direction reached no point on the square")

        local ax, ay, az = mapping.sphere(u :: number, v :: number)
        local off = away(ax, ay, az, x, y, z)
        Expect.holds(off <= degrees, `a direction came back {off} off at a step of {degrees}`)
    end),

    -- No pair a step away in either coordinate points nearer than the pair taken.
    Harness.property("rotation.octahedral-nearest", "leaves", function(rng: Rng.Rng)
        local grid = Grid.plane(rng:pick(DEGREES))
        local mapping = Rotation.octahedral(grid)
        local x, y, z = pointed(rng)
        local u, v = mapping.plane(x, y, z)
        Expect.holds(u ~= nil, "a drawn direction reached no point on the square")

        local atU, atV = u :: number, v :: number
        local ax, ay, az = mapping.sphere(atU, atV)
        local chosen = away(ax, ay, az, x, y, z)
        for stepU = -1, 1 do
            for stepV = -1, 1 do
                local tryU, tryV = atU + stepU, atV + stepV
                if tryU < 0 or tryU > grid.span or tryV < 0 or tryV > grid.span then continue end
                local bx, by, bz = mapping.sphere(tryU, tryV)
                local other = away(bx, by, bz, x, y, z)
                Expect.holds(
                    chosen <= other + HAIR,
                    `({tryU}, {tryV}) points nearer than the pair taken`
                )
            end
        end
    end),

    -- A vector of no length and a component that is no place both answer nothing, never a raise.
    Harness.case("rotation.octahedral-nowhere", function()
        local mapping = Rotation.octahedral(Grid.plane(DEGREES[3]))
        for _, one in
            { { 0, 0, 0 }, { 0 / 0, 0, 1 }, { 1, 0 / 0, 0 }, { 1 / 0, 1, 0 }, { 1, -1 / 0, 0 } }
        do
            local u, v = mapping.plane(one[1], one[2], one[3])
            Expect.equal(u, nil)
            Expect.equal(v, nil)
        end
    end),

    -- The identity names the fourth component and the three that travel are the grid's own zero.
    Harness.case("rotation.smallest-identity", function()
        local grid = Grid.chord(DEGREES[1])
        local mapping = Rotation.smallest(grid)
        local still = turn(0, 0, 0, 1)
        local tag, a, b, c = mapping.parts(matrix(still))
        Expect.equal(tag, QUAT_W)
        Expect.holds(a ~= nil, "the identity carried no indices")

        Expect.near(grid.fromIndex(a :: number), 0, NEARLY)
        Expect.near(grid.fromIndex(b :: number), 0, NEARLY)
        Expect.near(grid.fromIndex(c :: number), 0, NEARLY)
        Expect.near(
            between(spelled(mapping, tag, a :: number, b :: number, c :: number), still),
            0,
            HAIR
        )
    end),

    -- The answer is at least as near as every tag's plainest spelling, rounded with no search.
    Harness.property("rotation.smallest-nearest-of-every-tag", "leaves", function(rng: Rng.Rng)
        local grid = Grid.chord(rng:pick(DEGREES))
        local mapping = Rotation.smallest(grid)
        local of = drawn(rng)

        local tag, a, b, c = mapping.parts(matrix(of))
        Expect.holds(a ~= nil, "a drawn rotation carried no indices")
        local took = between(spelled(mapping, tag, a :: number, b :: number, c :: number), of)

        for other = QUAT_X, QUAT_W do
            local pa, pb, pc = travelling(other, of)
            local ia, ib, ic = grid.toIndex(pa), grid.toIndex(pb), grid.toIndex(pc)
            if ia == nil or ib == nil or ic == nil then continue end

            local ka = grid.fromIndex(ia :: number) :: number
            local kb = grid.fromIndex(ib :: number) :: number
            local kc = grid.fromIndex(ic :: number) :: number
            if ka * ka + kb * kb + kc * kc > 1 then continue end

            local off =
                between(spelled(mapping, other, ia :: number, ib :: number, ic :: number), of)
            Expect.holds(
                took <= off + HAIR,
                `the search took {took} off where tag {other} allows {off}`
            )
        end
    end),

    -- A rotation written at p degrees comes back within p degrees, measured as the angle between.
    Harness.property("rotation.smallest-precision", "leaves", function(rng: Rng.Rng)
        local degrees = rng:pick(DEGREES)
        local mapping = Rotation.smallest(Grid.chord(degrees))
        local of = drawn(rng)
        local tag, a, b, c = mapping.parts(matrix(of))
        Expect.holds(a ~= nil, "a drawn rotation carried no indices")

        local off = between(spelled(mapping, tag, a :: number, b :: number, c :: number), of)
        Expect.holds(off <= degrees, `a rotation came back {off} off at a step of {degrees}`)
    end),

    -- What comes back off the wire is written again by whoever holds it, and must be a fixed point.
    Harness.property("rotation.smallest-stable", "leaves", function(rng: Rng.Rng)
        local mapping = Rotation.smallest(Grid.chord(rng:pick(DEGREES)))
        local tag, a, b, c = mapping.parts(matrix(drawn(rng)))
        Expect.holds(a ~= nil, "a drawn rotation carried no indices")

        local x, y, z, w = mapping.whole(tag, a :: number, b :: number, c :: number)
        local againTag, againA, againB, againC = mapping.parts(matrix(turn(x, y, z, w)))
        Expect.equal(againTag, tag)
        Expect.equal(againA, a)
        Expect.equal(againB, b)
        Expect.equal(againC, c)
    end),

    -- A quaternion and its negation are one rotation, so they are one set of bytes.
    Harness.property("rotation.smallest-negation", "leaves", function(rng: Rng.Rng)
        local mapping = Rotation.smallest(Grid.chord(rng:pick(DEGREES)))
        local of = drawn(rng)
        local tag, a, b, c = mapping.parts(matrix(of))
        local flipped = { x = -of.x, y = -of.y, z = -of.z, w = -of.w }
        local otherTag, otherA, otherB, otherC = mapping.parts(matrix(flipped))
        Expect.equal(otherTag, tag)
        Expect.equal(otherA, a)
        Expect.equal(otherB, b)
        Expect.equal(otherC, c)
    end),

    -- The thirteen turns of a cube land on a grid point at every precision and come back exactly.
    Harness.case("rotation.smallest-exact", function()
        for _, degrees in DEGREES do
            local mapping = Rotation.smallest(Grid.chord(degrees))
            for _, of in square() do
                local tag, a, b, c = mapping.parts(matrix(of))
                Expect.holds(a ~= nil, `a cube turn carried no indices at a step of {degrees}`)
                local off =
                    between(spelled(mapping, tag, a :: number, b :: number, c :: number), of)
                Expect.holds(off <= HAIR, `a cube turn came back {off} degrees off`)
            end
        end
    end),

    -- Every index triple a frame can carry answers a unit quaternion, overrunning ones included.
    Harness.case("rotation.smallest-whole-total", function()
        local grid = Grid.chord(DEGREES[1])
        local mapping = Rotation.smallest(grid)
        for tag = QUAT_X, QUAT_W do
            for a = 0, grid.span do
                for b = 0, grid.span do
                    for c = 0, grid.span do
                        local x, y, z, w = mapping.whole(tag, a, b, c)
                        Expect.near(math.sqrt(x * x + y * y + z * z + w * w), 1, NEARLY)
                    end
                end
            end
        end
    end),

    -- A rotation two tags can spell is spelled by the lower of them.
    Harness.case("rotation.smallest-lowest-tag", function()
        local mapping = Rotation.smallest(Grid.chord(DEGREES[1]))
        local quarter = turn(BOUND, 0, 0, BOUND)
        local tag, a, b, c = mapping.parts(matrix(quarter))
        Expect.equal(tag, QUAT_X)
        Expect.holds(a ~= nil, "a quarter turn carried no indices")
        Expect.near(
            between(spelled(mapping, tag, a :: number, b :: number, c :: number), quarter),
            0,
            HAIR
        )
    end),

    -- The same matrix twice answers from memory, and a different one does not.
    Harness.case("rotation.smallest-remembers", function()
        local mapping = Rotation.smallest(Grid.chord(DEGREES[3]))
        local first = drawn(Rng.new(7))
        local tag, a, b, c = mapping.parts(matrix(first))
        local againTag, againA, againB, againC = mapping.parts(matrix(first))
        Expect.equal({ againTag, againA, againB, againC }, { tag, a, b, c })

        local otherTag, otherA, otherB, otherC = mapping.parts(matrix(turn(BOUND, 0, 0, BOUND)))
        Expect.equal(otherTag, QUAT_X)
        Expect.holds(
            otherA ~= a or otherB ~= b or otherC ~= c or otherTag ~= tag,
            "not remembered apart"
        )
    end),
}
