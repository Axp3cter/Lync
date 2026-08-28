--!strict
--!optimize 2
-- The quantization grid every ranged and stepped kind indexes through.

local Bits = require ("@src/kernel/Bits")
local Protocol = require ("@src/wire/Protocol")

local Grid = {}

-- Constants -----------------------------------------------------------

--[[
    A quarter turn, which is what an octahedral precision is read against: a component of the fold
    runs a quarter of the way round the sphere per unit, so a precision in degrees is that many
    ninetieths of one. A whole turn is not here, because an angle is the codec that declares one and
    a cyclic grid takes the range it is handed rather than a turn it assumes.
]]
const QUARTER = Protocol.QUARTER_TURN

-- How far the three components a smallest-three keeps can reach.
const BOUND = Protocol.QUAT_BOUND

-- What a division is allowed to be out by before its answer is read as the whole number it is.
const HAIR = 2 ^ -48

-- What a reading is allowed to be out by before it is read as the point it obviously is.
const READING = 2 ^ -20

-- Types ---------------------------------------------------------------

-- A mapping between the values a declaration carries and the indices the wire carries.
export type Grid = {
    read span: number,
    read width: number,
    read wrap: boolean?,
    read plain: boolean?,
    read whole: boolean?,
    read toIndex: (value: any) -> number?,
    read fromIndex: (index: number) -> any,

    --[[
        The pair of points a reading sits between, as indices and as the values at them, which a
        caller can assemble from the two above at the cost of asking five times over. A grid a
        search ever reaches for settles it once instead. A reading that is no place answers with
        the first index missing, which answers for a pair that has no other half either.
    ]]
    read window: ((value: any) -> (number?, number, number, number))?,
    --[[
        A whole run of readings at once, where a grid can answer for many faster than for one.
        `toIndices` fills `into` and answers the place of the first reading it has no point for,
        or nothing where every one landed. `fromIndices` turns indices back and says nothing about
        them, so a caller that has not already held every one of them to the grid may not use it.
    ]]
    read toIndices: ((values: { any }, into: { number }, count: number) -> number?)?,
    read fromIndices: ((indices: { number }, into: { any }, count: number) -> ())?,
}

-- Private -------------------------------------------------------------

-- What a number may be out by and still be the point it obviously is, at a stated width.
local function allowed (min: number, max: number, step: number, width: number): number
    return math.min ((max - min) * width, step / 2)
end

-- How many whole steps a range holds, which is a division and so not always the number it is.
local function spanned (min: number, max: number, step: number): number
    local whole = math.floor ((max - min) / step)
    if min + (whole + 1) * step <= max + allowed (min, max, step, HAIR) then return whole + 1 end

    return whole
end

-- Public --------------------------------------------------------------

--[[
    A midpoint rounds up. That is arbitrary and it is pinned, because two machines splitting one
    differently disagree about the bytes.
]]
function Grid.of (min: number, max: number, step: number, wraps: boolean?): Grid
    local span = spanned (min, max, step)
    local width = Bits.width (span)

    local function fromIndex (index: number): any return min + index * step end

    --[[
        A cyclic grid reduces the value into one turn before rounding, never the index after:
        rounding away from zero takes a midpoint up above the bottom and down below it, so a
        negative angle reduced afterwards lands a point off. The reduction is also the test for a
        reading that is no place on the line, since neither an infinity nor a NaN survives it.
    ]]
    if wraps then
        local points = span + 1
        local turn = points * step

        local function toIndex (value: any): number?
            if type (value) ~= "number" then return nil end

            local turned = (value - min) % turn
            if not (turned >= 0) then return nil end
            return math.round (turned / step) % points
        end

        return {
            span = span,
            width = width,
            wrap = true,
            toIndex = toIndex,
            fromIndex = fromIndex,
        }
    end

    --[[
        One test rather than two rejections, so a reading that is no place falls out of it as well.
        The index is clamped because a range holding two and a half steps rounds its top to three
        and the grid has two, and the nearest point a grid actually has is the last one.
    ]]
    local room = allowed (min, max, step, READING)
    local under = min - room
    local over = max + room

    --[[
        A grid from zero at a whole step is its own index, so the shift and the division are a
        subtraction of nothing and a division by one. Written apart rather than branched inside,
        since the branch would then be taken once a field on every frame.
    ]]
    if min == 0 and step == 1 then
        local toIndex: (value: any) -> number?
        local toIndices: (values: { any }, into: { number }, count: number) -> number?

        --[[
            A value the test let through is at most the slack out of place, so where the slack is
            under half a step it rounds back onto the grid by itself and holding it there is work
            no reading can reach. Only a range wide enough to make the slack a whole half needs it.
        ]]
        if room < step / 2 then
            toIndex = function (value: any): number?
                if type (value) ~= "number" then return nil end
                if not (value >= under and value <= over) then return nil end
                return math.round (value)
            end

            toIndices = function (values: { any }, into: { number }, count: number): number?
                for place = 1, count do
                    local one = values[place]
                    if type (one) ~= "number" then return place end
                    if not (one >= under and one <= over) then return place end

                    into[place] = math.round (one)
                end

                return nil
            end
        else
            toIndex = function (value: any): number?
                if type (value) ~= "number" then return nil end
                if not (value >= under and value <= over) then return nil end
                return math.clamp (math.round (value), 0, span)
            end

            toIndices = function (values: { any }, into: { number }, count: number): number?
                for place = 1, count do
                    local one = values[place]
                    if type (one) ~= "number" then return place end
                    if not (one >= under and one <= over) then return place end

                    into[place] = math.clamp (math.round (one), 0, span)
                end

                return nil
            end
        end

        return {
            span = span,
            width = width,
            plain = true,
            whole = span == bit32.lshift (1, width) - 1,
            toIndex = toIndex,
            fromIndex = fromIndex,

            --[[
                A whole list handed over at once, which a list is the one shape worth offering it
                for: what a caller of it spares is a crossing back an element, and the walk under it
                is the walk that would have been done out there anyway.
            ]]
            toIndices = toIndices,
        }
    end

    local function toIndex (value: any): number?
        if type (value) ~= "number" then return nil end
        if not (value >= under and value <= over) then return nil end
        return math.clamp (math.round ((value - min) / step), 0, span)
    end

    --[[
        The nearest point is worked out unclamped, since it is asked only whether it sits above the
        reading and a point off the end of the line answers that as truly as one on it. Where the
        reading is past an end both halves of the pair come back as the point nearest it, that
        being the only point on the side it is.
    ]]
    local function window (value: any): (number?, number, number, number)
        if type (value) ~= "number" then return nil, 0, 0, 0 end
        if not (value >= under and value <= over) then return nil, 0, 0, 0 end

        local at = math.round ((value - min) / step)
        local low = if min + at * step > value then at - 1 else at

        --[[
            Held to one end apiece. The slack a reading is let through by is never a whole step, so
            the point at or below one is never further than a step off either end of the line, and
            neither half of the pair can be off the end the other one is off.
        ]]
        local first = if low < 0 then 0 else low
        local second = if low < span then low + 1 else span
        return first, second, min + first * step, min + second * step
    end

    -- The same the other way, over readings a caller has already held to the grid itself.
    local function fromIndices (indices: { number }, into: { any }, count: number)
        for place = 1, count do
            into[place] = min + indices[place] * step
        end
    end

    return {
        span = span,
        width = width,
        plain = false,
        window = window,
        whole = span == bit32.lshift (1, width) - 1,
        toIndex = toIndex,
        fromIndex = fromIndex,
        fromIndices = fromIndices,
    }
end

-- One bit, and the two values it is, which is the one grid holding nothing a number could be.
function Grid.flag (): Grid
    local function toIndex (value: any): number?
        if value == true then return 1 end
        if value == false then return 0 end
        return nil
    end

    local function fromIndex (index: number): any return index == 1 end

    --[[
        The same two, for a run. A flag fills the one bit that carries it, so every reading a run
        of them can produce is a point this grid has and the taking half refuses nothing.
    ]]
    local function toIndices (values: { any }, into: { number }, count: number): number?
        for place = 1, count do
            local one = values[place]
            if one == true then
                into[place] = 1
            elseif one == false then
                into[place] = 0
            else
                return place
            end
        end

        return nil
    end

    local function fromIndices (indices: { number }, into: { any }, count: number)
        for place = 1, count do
            into[place] = indices[place] == 1
        end
    end

    return {
        span = 1,
        width = 1,
        whole = true,
        toIndex = toIndex,
        fromIndex = fromIndex,
        toIndices = toIndices,
        fromIndices = fromIndices,
    }
end

-- A ranged int over a count of things, which is where every tag and every chosen name lands.
function Grid.index (count: number): Grid return Grid.of (0, count - 1, 1) end

-- The names a declaration lists, indexed by where each one sits in it.
function Grid.named (names: { string }): Grid
    local span = #names - 1
    local index: { [string]: number } = {}

    for place, name in names do
        index[name] = place - 1
    end

    local function toIndex (value: any): number? return index[value] end
    local function fromIndex (at: number): any return names[at + 1] end

    --[[
        A list of names filling the bits it takes has one for every pattern those bits spell, so
        nothing off any bytes is off this grid and the walks that read it are spared asking. Said
        the way every other grid here says it, since it is the same question about the same span.
    ]]
    local width = Bits.width (span)

    return {
        span = span,
        width = width,
        whole = span == bit32.lshift (1, width) - 1,
        toIndex = toIndex,
        fromIndex = fromIndex,
    }
end

--[[
    One component of an octahedral mapping, which is the unit sphere folded onto a square and the
    square read at a precision in degrees. Both components are this, and nothing else is.
]]
function Grid.plane (precision: number): Grid return Grid.of (-1, 1, precision / QUARTER) end

--[[
    One component a smallest-three kept. The same number of points as a plane at the same precision,
    over a range scaled down by the bound: the component dropped was the largest, so no kept one is
    larger than it and two of them squared cannot pass one.
]]
function Grid.chord (precision: number): Grid
    return Grid.of (-BOUND, BOUND, BOUND * precision / QUARTER)
end

-- One channel of a packed colour, which is the whole of none to all of it in the bits it has.
function Grid.channel (bits: number): Grid return Grid.of (0, 1, 1 / (2 ^ bits - 1)) end

-- Whether a step divides a range, which is a division and so not always the answer it is.
function Grid.divides (reach: number, step: number): boolean
    local points = reach / step
    local near = math.round (points)

    return math.abs (points - near) < math.max (1, points) * HAIR
end

return table.freeze (Grid)
