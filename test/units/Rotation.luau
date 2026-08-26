--!strict
--!optimize 2
--[[
    The orientation mappings alone: a direction as a pair on a square, a turn as three of its four.
]]

local Grid = require ("@src/shape/Grid")
local Protocol = require ("@src/wire/Protocol")
local Rotation = require ("@src/shape/Rotation")
local Scalars = require ("@src/codec/Scalars")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Rng = require ("@test/harness/Rng")

-- Constants -----------------------------------------------------------

const AT_X = Protocol.QUAT_X
const AT_W = Protocol.QUAT_W
const BOUND = Protocol.QUAT_BOUND

--[[
    Precisions in degrees a case lays a grid at, coarsest first. Ninety is the coarsest a
    declaration can ask for and is where every rounding is widest, which is where a mapping that is
    nearly right stops being right. Half a degree is finer than anything a place has reason to send
    and is where a search that scores badly still looks correct.
]]
const DEGREES = table.freeze ({ 90, 45, 10, 5, 1, 0.5 })

--[[
    How far a value may sit from the one it should be and still count as it. Every number here comes
    off a square root and a normalize, so an exact answer arrives a part in 2^52 out.
]]
const NEARLY = 1e-9

-- The same margin for an angle read through an arc cosine, in degrees.
const HAIR = 1e-4

-- A whole turn, read from the module that declares it, and how many laps past one a case adds.
const TURN = Scalars.TURN
const LAPS = 3

-- How many draws a rejection sample takes before it gives up, which no run has ever reached.
const TRIES = 64

-- Types ---------------------------------------------------------------

type Turn = { x: number, y: number, z: number, w: number }

-- Private -------------------------------------------------------------

-- The four as one record, normalized on the way in, which is what every case here builds from.
local function turn (x: number, y: number, z: number, w: number): Turn
    local length = math.sqrt (x * x + y * y + z * z + w * w)
    return { x = x / length, y = y / length, z = z / length, w = w / length }
end

-- The twelve components a frame is read with, for a unit quaternion and no position.
local function matrix (of: Turn)
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

--[[
    A rotation drawn evenly over every rotation there is, which is a point drawn evenly on the unit
    sphere in four dimensions and reached by rejecting the corners of the cube around it.
]]
local function drawn (rng: Rng.Rng): Turn
    for _ = 1, TRIES do
        local x = Rng.number (rng, -1, 1)
        local y = Rng.number (rng, -1, 1)
        local z = Rng.number (rng, -1, 1)
        local w = Rng.number (rng, -1, 1)

        local held = x * x + y * y + z * z + w * w
        if held > NEARLY and held <= 1 then return turn (x, y, z, w) end
    end
    return turn (0, 0, 0, 1)
end

-- A direction drawn evenly over the sphere, which is a drawn rotation's own third column negated.
local function pointed (rng: Rng.Rng): (number, number, number)
    local of = drawn (rng)
    local x, y, z, w = of.x, of.y, of.z, of.w
    return -2 * (x * z + y * w), -2 * (y * z - x * w), -(1 - 2 * (x * x + y * y))
end

-- How far apart two rotations are in degrees, which a quaternion and its negation are none of.
local function between (left: Turn, right: Turn): number
    local dot = left.x * right.x + left.y * right.y + left.z * right.z + left.w * right.w
    return math.deg (2 * math.acos (math.min (1, math.abs (dot))))
end

-- How far apart two directions are in degrees.
local function away (
    ax: number,
    ay: number,
    az: number,
    bx: number,
    by: number,
    bz: number
): number
    return math.deg (math.acos (math.clamp (ax * bx + ay * by + az * bz, -1, 1)))
end

--[[
    The turns of a cube whose every component is a whole number or the bound itself, which is
    thirteen: the identity, a half turn about each axis, and a quarter turn each way about each.
    Every one of them sits on a grid point at every precision that divides the range evenly.
]]
local function square (): { Turn }
    local out = { turn (0, 0, 0, 1) }

    for _, axis in { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } } do
        local ax, ay, az = axis[1], axis[2], axis[3]

        table.insert (out, turn (ax, ay, az, 0))
        table.insert (out, turn (ax * BOUND, ay * BOUND, az * BOUND, BOUND))
        table.insert (out, turn (-ax * BOUND, -ay * BOUND, -az * BOUND, BOUND))
    end
    return out
end

-- Public --------------------------------------------------------------

return {
    --[[
        The six directions along an axis, which are the only ones a coarse grid holds exactly. At a
        precision of a quarter turn the square has three points a side, so the poles are corners of
        it and nothing rounds. What comes back is the direction that went in.
    ]]
    Harness.case ("rotation.octahedral-poles", function ()
        local mapping = Rotation.octahedral (Grid.plane (DEGREES[1]))

        local poles = {
            { 1, 0, 0 },
            { -1, 0, 0 },
            { 0, 1, 0 },
            { 0, -1, 0 },
            { 0, 0, 1 },
            { 0, 0, -1 },
        }

        for _, pole in poles do
            local x, y, z = pole[1], pole[2], pole[3]

            local u, v = mapping.plane (x, y, z)
            Expect.holds (u ~= nil and v ~= nil, `({x}, {y}, {z}) reached no point on the square`)

            local ax, ay, az = mapping.sphere (u :: number, v :: number)
            Expect.near (away (ax, ay, az, x, y, z), 0, HAIR)
        end
    end),

    --[[
        Every point of a coarse square, read back and written again. The second writing has to
        answer the first, which is the whole of what an encode matching its own decode's encode
        means, and it is not the same as the first writing answering the point it started from: a
        point on the outer edge has a second name and the read gives back only one of the two.
    ]]
    Harness.case ("rotation.octahedral-idempotent", function ()
        local grid = Grid.plane (DEGREES[2])
        local mapping = Rotation.octahedral (grid)

        for u = 0, grid.span do
            for v = 0, grid.span do
                local ax, ay, az = mapping.sphere (u, v)

                local firstU, firstV = mapping.plane (ax, ay, az)
                Expect.holds (firstU ~= nil, `({u}, {v}) read back as no direction at all`)

                local bx, by, bz = mapping.sphere (firstU :: number, firstV :: number)
                Expect.near (away (ax, ay, az, bx, by, bz), 0, HAIR)

                local againU, againV = mapping.plane (bx, by, bz)
                Expect.equal (againU, firstU)
                Expect.equal (againV, firstV)
            end
        end
    end),

    --[[
        Which half of the sphere a pair names. The near half fills the diamond the two coordinates
        sum to one inside, and everything outside it is the fold, so where a pair sits on the square
        decides the sign of the third component and nothing else does.
    ]]
    Harness.case ("rotation.octahedral-fold", function ()
        local grid = Grid.plane (DEGREES[2])
        local mapping = Rotation.octahedral (grid)

        for u = 0, grid.span do
            for v = 0, grid.span do
                local reach = math.abs (grid.fromIndex (u)) + math.abs (grid.fromIndex (v))
                local _, _, z = mapping.sphere (u, v)

                Expect.holds (
                    (z < 0) == (reach > 1),
                    `({u}, {v}) sits {reach} from the middle and points {z} up`
                )
            end
        end
    end),

    --[[
        A direction and any multiple of it. The mapping divides by the sum of the magnitudes rather
        than by the length, and that sum scales with the vector, so a caller handing over the vector
        it already has spends no square root. A scale that changed the bytes would make
        `vec3.bounded` and `vec3.unit` two different mappings wearing one name.
    ]]
    Harness.property ("rotation.octahedral-scale-free", "leaves", function (rng: Rng.Rng)
        local mapping = Rotation.octahedral (Grid.plane (Rng.pick (rng, DEGREES)))
        local x, y, z = pointed (rng)

        local u, v = mapping.plane (x, y, z)
        Expect.holds (u ~= nil, "a drawn direction reached no point on the square")

        local scale = Rng.number (rng, NEARLY, 1000)
        local scaledU, scaledV = mapping.plane (x * scale, y * scale, z * scale)

        Expect.equal (scaledU, u)
        Expect.equal (scaledV, v)
    end),

    --[[
        What the precision promises. A direction written at a precision of `p` degrees comes back
        within `p` degrees of itself, which is the claim the parameter's name makes and the reason
        the search scores corners rather than rounding each coordinate.
    ]]
    Harness.property ("rotation.octahedral-precision", "leaves", function (rng: Rng.Rng)
        local degrees = Rng.pick (rng, DEGREES)
        local mapping = Rotation.octahedral (Grid.plane (degrees))
        local x, y, z = pointed (rng)

        local u, v = mapping.plane (x, y, z)
        Expect.holds (u ~= nil, "a drawn direction reached no point on the square")

        local ax, ay, az = mapping.sphere (u :: number, v :: number)
        local off = away (ax, ay, az, x, y, z)
        Expect.holds (off <= degrees, `a direction came back {off} off at a step of {degrees}`)
    end),

    --[[
        The pair taken is the best one near it. Rounding each coordinate of the projection is the
        obvious way and it is not the nearest, because the projection is no isometry, so the answer
        is asked for as a local one: no pair a step away in either coordinate points nearer.
    ]]
    Harness.property ("rotation.octahedral-nearest", "leaves", function (rng: Rng.Rng)
        local grid = Grid.plane (Rng.pick (rng, DEGREES))
        local mapping = Rotation.octahedral (grid)
        local x, y, z = pointed (rng)

        local u, v = mapping.plane (x, y, z)
        Expect.holds (u ~= nil, "a drawn direction reached no point on the square")

        local atU, atV = u :: number, v :: number
        local ax, ay, az = mapping.sphere (atU, atV)
        local chosen = away (ax, ay, az, x, y, z)

        for stepU = -1, 1 do
            for stepV = -1, 1 do
                local tryU, tryV = atU + stepU, atV + stepV
                if tryU < 0 or tryU > grid.span or tryV < 0 or tryV > grid.span then continue end

                local bx, by, bz = mapping.sphere (tryU, tryV)
                local other = away (bx, by, bz, x, y, z)
                local why = `({tryU}, {tryV}) points nearer than the pair taken`
                Expect.holds (chosen <= other + HAIR, why)
            end
        end
    end),

    --[[
        A reading that is no direction at all. A vector of no length divides by nothing, and a
        component that is no place on the line carries that through every term, so both arrive at
        the grid as the value it already answers nothing for. Nothing is what a caller is written
        against, and a raise from inside a mapping would be a fault with no field on it.
    ]]
    Harness.case ("rotation.octahedral-nowhere", function ()
        local mapping = Rotation.octahedral (Grid.plane (DEGREES[3]))

        local nowhere = {
            { 0, 0, 0 },
            { 0 / 0, 0, 1 },
            { 1, 0 / 0, 0 },
            { 1 / 0, 1, 0 },
            { 1, -1 / 0, 0 },
        }

        for _, one in nowhere do
            local u, v = mapping.plane (one[1], one[2], one[3])
            Expect.equal (u, nil)
            Expect.equal (v, nil)
        end
    end),

    --[[
        The rotation that is none. Every diagonal entry is one, so the trace is three and the branch
        that is best conditioned is the one naming the fourth component, which is the tag a reader
        takes as three. The three that travel are each the grid's own zero.
    ]]
    Harness.case ("rotation.smallest-identity", function ()
        local grid = Grid.chord (DEGREES[1])
        local mapping = Rotation.smallest (grid)

        local still = turn (0, 0, 0, 1)
        local tag, a, b, c = mapping.parts (matrix (still))
        Expect.equal (tag, AT_W)
        Expect.holds (a ~= nil, "the identity carried no indices")

        Expect.near (grid.fromIndex (a :: number), 0, NEARLY)
        Expect.near (grid.fromIndex (b :: number), 0, NEARLY)
        Expect.near (grid.fromIndex (c :: number), 0, NEARLY)

        local x, y, z, w = mapping.whole (tag, a :: number, b :: number, c :: number)
        Expect.near (between ({ x = x, y = y, z = z, w = w }, still), 0, HAIR)
    end),

    --[[
        What the precision promises for a turn. A rotation written at `p` degrees comes back within
        `p` degrees of itself, measured as the angle between the two rather than component by
        component, because a component is not what a caller of `rotation.quat` is holding.
    ]]
    Harness.property ("rotation.smallest-precision", "leaves", function (rng: Rng.Rng)
        local degrees = Rng.pick (rng, DEGREES)
        local mapping = Rotation.smallest (Grid.chord (degrees))
        local of = drawn (rng)

        local tag, a, b, c = mapping.parts (matrix (of))
        Expect.holds (a ~= nil, "a drawn rotation carried no indices")

        local x, y, z, w = mapping.whole (tag, a :: number, b :: number, c :: number)
        local off = between ({ x = x, y = y, z = z, w = w }, of)
        Expect.holds (off <= degrees, `a rotation came back {off} off at a step of {degrees}`)
    end),

    --[[
        The same rotation twice. What comes back off the wire is written again by whoever holds it,
        so a mapping whose second writing differs from its first sends a frame every flush for a
        value nobody changed. Two writings are asked for rather than one, because the first is where
        rounding happens and every one after it has to be a fixed point.
    ]]
    Harness.property ("rotation.smallest-stable", "leaves", function (rng: Rng.Rng)
        local mapping = Rotation.smallest (Grid.chord (Rng.pick (rng, DEGREES)))

        local tag, a, b, c = mapping.parts (matrix (drawn (rng)))
        Expect.holds (a ~= nil, "a drawn rotation carried no indices")

        local x, y, z, w = mapping.whole (tag, a :: number, b :: number, c :: number)
        local againTag, againA, againB, againC = mapping.parts (matrix (turn (x, y, z, w)))

        Expect.equal (againTag, tag)
        Expect.equal (againA, a)
        Expect.equal (againB, b)
        Expect.equal (againC, c)
    end),

    --[[
        A quaternion and its negation are one rotation, so they are one set of bytes. Nothing here
        normalizes a sign on the way in: the branch that extracts writes its own component as a
        positive root, which picks the same one of the pair every time and is why there is no rule
        to state.
    ]]
    Harness.property ("rotation.smallest-negation", "leaves", function (rng: Rng.Rng)
        local mapping = Rotation.smallest (Grid.chord (Rng.pick (rng, DEGREES)))
        local of = drawn (rng)

        local tag, a, b, c = mapping.parts (matrix (of))
        local flipped = { x = -of.x, y = -of.y, z = -of.z, w = -of.w }
        local otherTag, otherA, otherB, otherC = mapping.parts (matrix (flipped))

        Expect.equal (otherTag, tag)
        Expect.equal (otherA, a)
        Expect.equal (otherB, b)
        Expect.equal (otherC, c)
    end),

    --[[
        The thirteen turns of a cube, whose components are all whole numbers or the bound itself.
        Every one of them lands on a grid point at every precision here, so these come back exactly
        rather than within the promise. A quarter turn is also where two of the four extraction
        branches are level, which is the tie the margin decides.
    ]]
    Harness.case ("rotation.smallest-exact", function ()
        for _, degrees in DEGREES do
            local mapping = Rotation.smallest (Grid.chord (degrees))

            for _, of in square () do
                local tag, a, b, c = mapping.parts (matrix (of))
                Expect.holds (a ~= nil, `a cube turn carried no indices at a step of {degrees}`)

                local x, y, z, w = mapping.whole (tag, a :: number, b :: number, c :: number)
                local off = between ({ x = x, y = y, z = z, w = w }, of)
                Expect.holds (off <= HAIR, `a cube turn came back {off} degrees off`)
            end
        end
    end),

    --[[
        Every index triple a frame can carry, including the ones that overrun. Three components
        already past a unit quaternion leave nothing for the fourth rather than the root of a
        negative number, and what comes back is normalized, so every reading is a rotation and none
        of them is the quaternion of no length at all.
    ]]
    Harness.case ("rotation.smallest-whole-total", function ()
        local grid = Grid.chord (DEGREES[1])
        local mapping = Rotation.smallest (grid)

        for tag = AT_X, AT_W do
            for a = 0, grid.span do
                for b = 0, grid.span do
                    for c = 0, grid.span do
                        local x, y, z, w = mapping.whole (tag, a, b, c)
                        Expect.near (math.sqrt (x * x + y * y + z * z + w * w), 1, NEARLY)
                    end
                end
            end
        end
    end),

    --[[
        A rotation two tags can spell is spelled by the lower of them. Which of the two is nearer
        depends on the value asked about, so nearest is not an order the bytes can rest on, and the
        last word goes to whether a lower tag can spell the answer exactly rather than to which tag
        the question preferred.
    ]]
    Harness.case ("rotation.smallest-lowest-tag", function ()
        local mapping = Rotation.smallest (Grid.chord (DEGREES[1]))

        -- A quarter turn about X, whose largest is a tie between that component and the fourth.
        local quarter = turn (BOUND, 0, 0, BOUND)
        local tag, a, b, c = mapping.parts (matrix (quarter))
        Expect.equal (tag, AT_X)
        Expect.holds (a ~= nil, "a quarter turn carried no indices")

        local x, y, z, w = mapping.whole (tag, a :: number, b :: number, c :: number)
        Expect.near (between ({ x = x, y = y, z = z, w = w }, quarter), 0, HAIR)
    end),

    --[[
        The angle a frame turns through, over the grid an axial declaration cuts. It comes off the
        matrix rather than out of a library call, and the trace and the
        antisymmetric part together name it once round rather than twice, which a cosine alone
        cannot do.
    ]]
    Harness.property ("rotation.axial-round-trip", "leaves", function (rng: Rng.Rng)
        local degrees = Rng.pick (rng, DEGREES)
        local grid = Grid.of (0, TURN - degrees, degrees, true)

        local ax, ay, az = pointed (rng)
        local mapping = Rotation.axial (grid, ax, ay, az)

        local at = Rng.int (rng, 0, grid.span)
        local x, y, z, w = mapping.whole (at)
        Expect.equal (mapping.parts (matrix (turn (x, y, z, w))), at)
    end),

    --[[
        Any lap of the same turn. The grid is cyclic and the matrix of an angle is the matrix of
        that angle a whole turn later, so nothing here reduces first and a caller handing over a
        rotation that has been round three times reaches the index it would have reached at once.
    ]]
    Harness.property ("rotation.axial-laps", "leaves", function (rng: Rng.Rng)
        local degrees = Rng.pick (rng, DEGREES)
        local grid = Grid.of (0, TURN - degrees, degrees, true)

        local ax, ay, az = pointed (rng)
        local mapping = Rotation.axial (grid, ax, ay, az)

        local at = Rng.int (rng, 0, grid.span)
        local angle = math.rad (grid.fromIndex (at) + Rng.int (rng, -LAPS, LAPS) * TURN) / 2
        local turned = math.sin (angle)

        local of = turn (ax * turned, ay * turned, az * turned, math.cos (angle))
        Expect.equal (mapping.parts (matrix (of)), at)
    end),

    --[[
        An axis of any length. A declaration hands over a direction rather than a unit, and an axis
        that was not normalized would put a sine that is not one into every angle read off a matrix
        and into every quaternion written back. Normalized once where the mapping is built, so no
        call pays for it.
    ]]
    Harness.property ("rotation.axial-any-length", "leaves", function (rng: Rng.Rng)
        local degrees = Rng.pick (rng, DEGREES)
        local grid = Grid.of (0, TURN - degrees, degrees, true)

        local ax, ay, az = pointed (rng)
        local scale = Rng.number (rng, NEARLY, 1000)

        local unit = Rotation.axial (grid, ax, ay, az)
        local long = Rotation.axial (grid, ax * scale, ay * scale, az * scale)

        local at = Rng.int (rng, 0, grid.span)
        local x, y, z, w = unit.whole (at)
        local bx, by, bz, bw = long.whole (at)

        local held = { x = bx, y = by, z = bz, w = bw }
        Expect.near (between ({ x = x, y = y, z = z, w = w }, held), 0, HAIR)
        Expect.equal (long.parts (matrix (turn (x, y, z, w))), at)
    end),

    --[[
        Every index a cyclic angle grid holds. What comes back is a unit quaternion and it turns
        about the axis that was declared and no other, which is the whole of what a one-parameter
        rotation is. Read as the part of the vector lying along the axis being all of it.
    ]]
    Harness.case ("rotation.axial-whole-total", function ()
        local grid = Grid.of (0, TURN - DEGREES[3], DEGREES[3], true)
        local mapping = Rotation.axial (grid, 1, 2, 3)

        local length = math.sqrt (1 + 4 + 9)
        local nx, ny, nz = 1 / length, 2 / length, 3 / length

        for at = 0, grid.span do
            local x, y, z, w = mapping.whole (at)
            Expect.near (math.sqrt (x * x + y * y + z * z + w * w), 1, NEARLY)

            local along = x * nx + y * ny + z * nz
            Expect.near (math.sqrt (x * x + y * y + z * z), math.abs (along), NEARLY)
        end
    end),

    --[[
        A look direction, out and back. The direction is the frame's own third column negated, and
        what comes back is the shortest turn onto it, so the frame this answers is not the frame
        that was asked about and the direction it looks in is.
    ]]
    Harness.property ("rotation.facing-round-trip", "leaves", function (rng: Rng.Rng)
        local mapping = Rotation.facing (Grid.plane (Rng.pick (rng, DEGREES)))
        local of = drawn (rng)

        local u, v = mapping.parts (matrix (of))
        Expect.holds (u ~= nil, "a drawn frame looked nowhere")

        local x, y, z, w = mapping.whole (u :: number, v :: number)
        local againU, againV = mapping.parts (matrix (turn (x, y, z, w)))

        Expect.equal (againU, u)
        Expect.equal (againV, v)
    end),

    --[[
        The shortest turn has no roll. Its axis is the cross of the frame that looks down the
        negative Z with the direction wanted, and both of those lie in the plane the world's own Z
        is normal to, so the third component is zero at every point of the square.
    ]]
    Harness.case ("rotation.facing-no-roll", function ()
        local grid = Grid.plane (DEGREES[2])
        local mapping = Rotation.facing (grid)

        for u = 0, grid.span do
            for v = 0, grid.span do
                local x, y, z, w = mapping.whole (u, v)
                Expect.near (z, 0, NEARLY)
                Expect.near (math.sqrt (x * x + y * y + z * z + w * w), 1, NEARLY)
            end
        end
    end),

    --[[
        Directly behind, which is the one direction the shortest turn does not name. Every axis
        through the frame is shortest there, so the answer is declared rather than computed: a half
        turn about the world's up, which two machines rounding one direction both arrive at.
    ]]
    Harness.case ("rotation.facing-behind", function ()
        local mapping = Rotation.facing (Grid.plane (DEGREES[1]))

        -- A half turn about the world's up is the frame that looks the other way.
        local u, v = mapping.parts (matrix (turn (0, 1, 0, 0)))
        Expect.holds (u ~= nil, "the frame looking behind reached no point on the square")

        local x, y, z, w = mapping.whole (u :: number, v :: number)
        Expect.near (x, 0, NEARLY)
        Expect.near (y, 1, NEARLY)
        Expect.near (z, 0, NEARLY)
        Expect.near (w, 0, NEARLY)
    end),
}
