--!strict
--!optimize 2
--[[
    The orientation mappings: a direction folded onto a square, a turn as the three components it
    keeps, and a turn about one declared axis as the angle alone.
]]

local Grid = require ("@src/shape/Grid")
local Protocol = require ("@src/wire/Protocol")

local Rotation = {}

-- Constants -----------------------------------------------------------

-- Hoisted so the tag a branch writes is a capture rather than a read through two tables.
const AT_X = Protocol.QUAT_X
const AT_Y = Protocol.QUAT_Y
const AT_Z = Protocol.QUAT_Z
const AT_W = Protocol.QUAT_W

-- How near two of the four have to be before the first of them wins.
const LEVEL = 1e-9

-- How much better one spelling of a rotation has to score before it is taken as better at all.
const TIGHTER = 1 - 1e-9

-- How near a component has to sit to a grid point before it is called one.
const NEARLY = 1e-9

-- Types ---------------------------------------------------------------

--[[
    A direction, either way. `plane` answers the two grid indices the wire carries, and nil for a
    reading that is no direction at all. `sphere` takes those indices back to a unit vector.
]]
export type Octahedral = {
    read plane: (x: number, y: number, z: number) -> (number?, number?),
    read sphere: (u: number, v: number) -> (number, number, number),
}

--[[
    A turn, either way, and a pair that is a matrix in and a quaternion out. The platform builds a
    CFrame from four numbers and hands none of them back, so the way in is off the rotation matrix
    and the way out is the four the constructor takes.
]]
export type Smallest = {
    read parts: (
        _x: number,
        _y: number,
        _z: number,
        r00: number,
        r01: number,
        r02: number,
        r10: number,
        r11: number,
        r12: number,
        r20: number,
        r21: number,
        r22: number
    ) -> (number, number?, number?, number?),
    read whole: (
        largest: number,
        a: number,
        b: number,
        c: number
    ) -> (number, number, number, number),
}

--[[
    A turn about one declared axis, either way. `parts` answers the grid index of the angle and
    nothing for a matrix that is no rotation at all, and `whole` answers the quaternion at that
    index. It speaks the twelve components a frame is read with, for the reason the smallest three
    does: that is one call at the boundary and nothing here then names a datatype.
]]
export type Axial = {
    read parts: (
        _x: number,
        _y: number,
        _z: number,
        r00: number,
        r01: number,
        r02: number,
        r10: number,
        r11: number,
        r12: number,
        r20: number,
        r21: number,
        r22: number
    ) -> number?,
    read whole: (at: number) -> (number, number, number, number),
}

-- A look direction, either way, as the same square a unit vector folds onto.
export type Facing = {
    read parts: (
        _x: number,
        _y: number,
        _z: number,
        r00: number,
        r01: number,
        r02: number,
        r10: number,
        r11: number,
        r12: number,
        r20: number,
        r21: number,
        r22: number
    ) -> (number?, number?),
    read whole: (u: number, v: number) -> (number, number, number, number),
}

-- Private -------------------------------------------------------------

--[[
    Zero counts as positive. That is what makes the fold total: a component sitting exactly on an
    axis has to go the same way on both machines, and it is why neither `math.sign` nor
    `vector.sign` can stand here, since both answer zero for zero and one of the two folds is then a
    reflection through nothing.
]]
local function sign (value: number): number return if value >= 0 then 1 else -1 end

--[[
    The fold, which is its own inverse. The far half of the sphere reflects across the square's two
    diagonals, and the same two lines carry it back, so both directions of the mapping share this
    rather than each spelling a reflection out and one of them wearing a sign the other does not.
]]
local function folded (u: number, v: number): (number, number)
    return (1 - math.abs (v)) * sign (u), (1 - math.abs (u)) * sign (v)
end

-- The one of the two names a point on the square's outer edge has.
local function only (span: number, atU: number, atV: number): (number, number)
    local edgeU = atU == 0 or atU == span
    local edgeV = atV == 0 or atV == span

    if edgeU and span - atV > atV then atV = span - atV end
    if edgeV and span - atU > atU then atU = span - atU end
    return atU, atV
end

--[[
    The lower index of the two the value lies between, where a search of a grid cell starts. Asked
    of the grid where it answers for that, since working it out from the two below asks the same
    grid twice for what it settles once, and a search asks three times a spelling it tries.
]]
local function windows (of: Grid.Grid): (value: any) -> (number?, number, number, number)
    local ready = of.window
    if ready ~= nil then return ready end

    local span, toIndex, fromIndex = of.span, of.toIndex, of.fromIndex
    return function (value: any): (number?, number, number, number)
        local at = toIndex (value)
        if at == nil then return nil, 0, 0, 0 end

        local low = if fromIndex (at) > value then at - 1 else at
        local first = math.clamp (low, 0, span)
        local second = math.clamp (low + 1, 0, span)
        return first, second, fromIndex (first), fromIndex (second)
    end
end

-- Public --------------------------------------------------------------

--[[
    The octahedral mapping over one grid, which is `vec3.unit`, the direction half of
    `vec3.bounded`, and `rotation.direction`.
]]
function Rotation.octahedral (of: Grid.Grid): Octahedral
    local span, fromIndex, window = of.span, of.fromIndex, windows (of)

    local function sphere (u: number, v: number): (number, number, number)
        local x, y = fromIndex (u), fromIndex (v)
        local z = 1 - math.abs (x) - math.abs (y)
        if z < 0 then
            x, y = folded (x, y)
        end

        local length = math.sqrt (x * x + y * y + z * z)
        return x / length, y / length, z / length
    end

    --[[
        The pair whose direction is nearest, rather than the pair nearest the projection. The
        projection is no isometry, so rounding each coordinate lands as much as a sixth of a step
        past the arc the precision promises, and one of the cell's four corners always does better.
        A corner is scored by how far along the vector it points, which needs no length.
    ]]
    local function plane (x: number, y: number, z: number): (number?, number?)
        local reach = math.abs (x) + math.abs (y) + math.abs (z)
        local u, v = x / reach, y / reach
        if z < 0 then
            u, v = folded (u, v)
        end

        local u0, u1 = window (u)
        local v0, v1 = window (v)
        if u0 == nil or v0 == nil then return nil, nil end

        local best, atU, atV = -math.huge, u0, v0
        for stepU = 0, 1 do
            local tryU = if stepU == 0 then u0 else u1
            for stepV = 0, 1 do
                local tryV = if stepV == 0 then v0 else v1

                local ax, ay, az = sphere (tryU, tryV)
                local along = ax * x + ay * y + az * z
                if along > best then
                    best, atU, atV = along, tryU, tryV
                end
            end
        end
        return only (span, atU, atV)
    end

    return table.freeze ({ plane = plane, sphere = sphere })
end

-- The smallest-three mapping over one grid, which is `rotation.quat` alone.
function Rotation.smallest (of: Grid.Grid): Smallest
    local fromIndex, window = of.fromIndex, windows (of)

    -- The three a tag sends and the one it leaves behind.
    local function apart (
        tag: number,
        x: number,
        y: number,
        z: number,
        w: number
    ): (number, number, number, number)
        -- The one of q and -q whose named component is positive, since both spell one rotation.
        local named = w
        if tag == AT_X then
            named = x
        elseif tag == AT_Y then
            named = y
        elseif tag == AT_Z then
            named = z
        end

        if named < 0 then
            x, y, z, w = -x, -y, -z, -w
        end

        if tag == AT_X then return y, z, w, x end
        if tag == AT_Y then return x, z, w, y end
        if tag == AT_Z then return x, y, w, z end
        return x, y, z, w
    end

    -- The three that travelled and the one rebuilt from them, back in component order.
    local function laid (
        largest: number,
        a: number,
        b: number,
        c: number,
        d: number
    ): (number, number, number, number)
        if largest == AT_X then return d, a, b, c end
        if largest == AT_Y then return a, d, b, c end
        if largest == AT_Z then return a, b, d, c end
        return a, b, c, d
    end

    --[[
        The dropped component is positive and is whatever is left of a unit quaternion, so a frame
        claiming three that already overrun one leaves nothing for it rather than a root of a
        negative. Every index pair a frame can carry answers a quaternion here, and none of them
        answers a zero one, because three zeros leave the fourth at one.
    ]]
    local function whole (
        largest: number,
        a: number,
        b: number,
        c: number
    ): (number, number, number, number)
        local ka, kb, kc = fromIndex (a), fromIndex (b), fromIndex (c)
        local x, y, z, w =
            laid (largest, ka, kb, kc, math.sqrt (math.max (0, 1 - ka * ka - kb * kb - kc * kc)))

        local length = math.sqrt (x * x + y * y + z * z + w * w)
        return x / length, y / length, z / length, w / length
    end

    --[[
        The three indices whose quaternion is nearest, for the reason the direction search gives:
        the rebuilt component moves with all three others, so the triple nearest component by
        component is not the triple nearest as a rotation. One of the cell's eight corners is always
        the answer.
    ]]
    local function searched (
        _x: number,
        _y: number,
        _z: number,
        r00: number,
        r01: number,
        r02: number,
        r10: number,
        r11: number,
        r12: number,
        r20: number,
        r21: number,
        r22: number
    ): (number, number?, number?, number?)
        local trace = r00 + r11 + r22

        --[[
            Which of the four is largest, and the first of them where they are level. The branch
            decides which component is dropped, so it decides the bytes, and a quarter turn makes
            two of them equal to within a last bit rather than exactly. A strict comparison let that
            bit choose, and the two took turns forever.
        ]]
        local top = math.max (trace, r00, r11, r22) - LEVEL

        local largest, a, b, c, d
        if trace >= top then
            local s = math.sqrt (trace + 1) * 2
            largest, d = AT_W, 0.25 * s
            a, b, c = (r21 - r12) / s, (r02 - r20) / s, (r10 - r01) / s
        elseif r00 >= top then
            local s = math.sqrt (1 + r00 - r11 - r22) * 2
            largest, d = AT_X, 0.25 * s
            a, b, c = (r01 + r10) / s, (r02 + r20) / s, (r21 - r12) / s
        elseif r11 >= top then
            local s = math.sqrt (1 + r11 - r00 - r22) * 2
            largest, d = AT_Y, 0.25 * s
            a, b, c = (r01 + r10) / s, (r12 + r21) / s, (r02 - r20) / s
        else
            local s = math.sqrt (1 + r22 - r00 - r11) * 2
            largest, d = AT_Z, 0.25 * s
            a, b, c = (r02 + r20) / s, (r12 + r21) / s, (r10 - r01) / s
        end

        --[[
            Held to unit length before anything is placed on a grid. A matrix carried in float32
            spells a quaternion a last bit of that width off one, and a CFrame carries its matrix in
            float32.
        ]]
        local x, y, z, w = laid (largest, a, b, c, d)

        local length = math.sqrt (x * x + y * y + z * z + w * w)
        x, y, z, w = x / length, y / length, z / length, w / length

        --[[
            The one the branch named travels under every tag but its own, and nothing is larger
            than it, so a grid holding it holds all four and a grid without it holds none of those
            three. The three would each ask and each be told the same, so one asking answers them.
        ]]
        local most = w
        if largest == AT_X then
            most = x
        elseif largest == AT_Y then
            most = y
        elseif largest == AT_Z then
            most = z
        end

        local reached = window (most) ~= nil

        --[[
            Every tag tried, and the nearest answer taken. The branch above names the largest of the
            exact quaternion, which cannot be the whole choice: the three that travel are rounded,
            so the bytes name one tag while the value they rebuild wants another.
        ]]
        local best, took, atA, atB, atC = math.huge, largest, nil, nil, nil
        for tag = AT_X, AT_W do
            if not reached and tag ~= largest then continue end

            local pa, pb, pc, pd = apart (tag, x, y, z, w)

            --[[
                Each of the three moves by one step at most, so there are two spellings of each
                and two readings, and eight triples over them. The loops vary which of the two a
                triple takes and never what the two are, so the grid is asked for the pair once
                and answers with the readings already on it.
            ]]
            local a0, a1, ka0, ka1 = window (pa)
            if a0 == nil then continue end

            local b0, b1, kb0, kb1 = window (pb)
            if b0 == nil then continue end

            local c0, c1, kc0, kc1 = window (pc)
            if c0 == nil then continue end

            for stepA = 0, 1 do
                local tryA = if stepA == 0 then a0 else a1
                local ka = if stepA == 0 then ka0 else ka1
                local sumA = ka * ka

                -- The first gap squared, which the four triples under this one all share.
                local da = ka - pa
                local gapA = da * da

                for stepB = 0, 1 do
                    local tryB = if stepB == 0 then b0 else b1
                    local kb = if stepB == 0 then kb0 else kb1
                    local sumB = sumA + kb * kb

                    -- The first two gaps, which the two triples under this one both share.
                    local db = kb - pb
                    local gapB = gapA + db * db

                    for stepC = 0, 1 do
                        local tryC = if stepC == 0 then c0 else c1
                        local kc = if stepC == 0 then kc0 else kc1

                        -- A triple that overruns the unit quaternion, which spells nothing.
                        local over = sumB + kc * kc
                        if over > 1 then continue end

                        --[[
                            Three of the four gaps before the fourth is worked out, since the
                            fourth is a root and the three already answer for most triples: what
                            the root adds cannot be less than nothing, so a triple already further
                            than the best is further whatever the root comes to.
                        ]]
                        local dc = kc - pc
                        local part = gapB + dc * dc
                        if part >= best * TIGHTER then continue end

                        local kd = math.sqrt (math.max (0, 1 - over))
                        local dd = kd - pd
                        local away = part + dd * dd

                        -- Nearer wins, and where two are level the smaller spelling does.
                        if away < best * TIGHTER then
                            best, took, atA, atB, atC = away, tag, tryA, tryB, tryC
                        end
                    end
                end
            end
        end

        if atA == nil or atB == nil or atC == nil then return largest, nil, nil, nil end

        local heldA, heldB, heldC = atA :: number, atB :: number, atC :: number

        --[[
            The same rotation, spelled by the lowest tag that can spell it exactly. Nearest is not a
            choice a rotation can be held to, since which of two tags is nearer depends on the value
            asked about and the bytes then take turns.
        ]]
        local qx, qy, qz, qw = whole (took, heldA, heldB, heldC)
        for tag = AT_X, took - 1 do
            local pa, pb, pc, pd = apart (tag, qx, qy, qz, qw)

            local ia, ib, ic = of.toIndex (pa), of.toIndex (pb), of.toIndex (pc)
            if ia == nil or ib == nil or ic == nil then continue end

            local ka, kb, kc = fromIndex (ia), fromIndex (ib), fromIndex (ic)
            local over = ka * ka + kb * kb + kc * kc
            if over > 1 then continue end

            local kd = math.sqrt (math.max (0, 1 - over))
            local off = math.abs (ka - pa) + math.abs (kb - pb) + math.abs (kc - pc)
            if off + math.abs (kd - pd) > NEARLY then continue end

            return tag, ia, ib, ic
        end

        return took, heldA, heldB, heldC
    end

    --[[
        The last matrix asked about and what it answered. A sender standing still, or turning about
        one axis, hands the same rotation frame after frame, and the search above walks eight
        corners over four tags every time it is asked. Nine comparisons buy skipping all of it.
    ]]
    local warm = false
    local w00, w01, w02, w10, w11, w12, w20, w21, w22 = 0, 0, 0, 0, 0, 0, 0, 0, 0
    local gotTag, gotA, gotB, gotC = 0, nil :: number?, nil :: number?, nil :: number?

    local function parts (
        x: number,
        y: number,
        z: number,
        r00: number,
        r01: number,
        r02: number,
        r10: number,
        r11: number,
        r12: number,
        r20: number,
        r21: number,
        r22: number
    ): (number, number?, number?, number?)
        if
            warm
            and r00 == w00
            and r01 == w01
            and r02 == w02
            and r10 == w10
            and r11 == w11
            and r12 == w12
            and r20 == w20
            and r21 == w21
            and r22 == w22
        then
            return gotTag, gotA, gotB, gotC
        end

        local tag, ia, ib, ic = searched (x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)

        w00, w01, w02 = r00, r01, r02
        w10, w11, w12 = r10, r11, r12
        w20, w21, w22 = r20, r21, r22
        gotTag, gotA, gotB, gotC = tag, ia, ib, ic
        warm = true

        return tag, ia, ib, ic
    end

    return table.freeze ({ parts = parts, whole = whole })
end

-- A turn about one axis the declaration named, over the cyclic grid its precision cuts.
function Rotation.axial (of: Grid.Grid, ax: number, ay: number, az: number): Axial
    local length = math.sqrt (ax * ax + ay * ay + az * az)
    local nx, ny, nz = ax / length, ay / length, az / length

    local toIndex, fromIndex = of.toIndex, of.fromIndex

    local function parts (
        _x: number,
        _y: number,
        _z: number,
        r00: number,
        r01: number,
        r02: number,
        r10: number,
        r11: number,
        r12: number,
        r20: number,
        r21: number,
        r22: number
    ): number?
        local along = (r21 - r12) * nx + (r02 - r20) * ny + (r10 - r01) * nz
        return toIndex (math.deg (math.atan2 (along / 2, (r00 + r11 + r22 - 1) / 2)))
    end

    local function whole (at: number): (number, number, number, number)
        local half = math.rad (fromIndex (at)) / 2
        local turned = math.sin (half)

        return nx * turned, ny * turned, nz * turned, math.cos (half)
    end

    return table.freeze ({ parts = parts, whole = whole })
end

-- A look direction on the octahedral square, and the shortest turn back onto it.
function Rotation.facing (of: Grid.Grid): Facing
    local mapping = Rotation.octahedral (of)
    local plane, sphere = mapping.plane, mapping.sphere

    local function parts (
        _x: number,
        _y: number,
        _z: number,
        r00: number,
        r01: number,
        r02: number,
        r10: number,
        r11: number,
        r12: number,
        r20: number,
        r21: number,
        r22: number
    ): (number?, number?)
        return plane (-r02, -r12, -r22)
    end

    local function whole (u: number, v: number): (number, number, number, number)
        local tx, ty, tz = sphere (u, v)
        local w = 1 - tz

        if w <= 0 then return 0, 1, 0, 0 end

        local length = math.sqrt (ty * ty + tx * tx + w * w)
        return ty / length, -tx / length, 0, w / length
    end

    return table.freeze ({ parts = parts, whole = whole })
end

return table.freeze (Rotation)
