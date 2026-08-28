--!strict
--!native
--!optimize 2
-- One field of a set across many records, as the pair of closures that lay that column down.

local Catalog = require ("@src/kernel/Catalog")
local Grid = require ("@src/shape/Grid")
local Ir = require ("@src/shape/Ir")
local Leaf = require ("@src/shape/emit/Leaf")
local Log = require ("@src/kernel/Log")
local Serial = require ("@src/shape/Serial")
local Types = require ("@src/Types")
local Varint = require ("@src/wire/Varint")
local Word = require ("@src/shape/emit/Word")

local Column = {}

-- Constants -----------------------------------------------------------

--[[
    The two run walkers under their own names. Both sit inside closures this emits, so each is
    reached once a run rather than once a build, and the module they come from is the same table
    for the life of the place.
]]
const PACKED = Leaf.packed
const UNPACKED = Leaf.unpacked

-- Types ---------------------------------------------------------------

--[[
    A column, and the arrays either end of it. The values are positional, so a caller reads its slot
    list once to gather and once to scatter. A closure that gathered for itself would owe the reader
    a rule for a slot the receiver does not hold, and scattering what it holds is that rule with no
    branch in it.
]]
export type Write = (b: buffer, pos: number, from: { any }, at: { number }, count: number) -> number
export type Read = (
    b: buffer,
    pos: number,
    into: { any },
    at: { number },
    count: number,
    ctx: Types.ValidateContext
) -> number

export type Gain = (
    b: buffer,
    pos: number,
    from: { any },
    slots: { number },
    was: { [number]: number },
    at: { number },
    count: number
) -> number

export type Regain = (
    b: buffer,
    pos: number,
    into: { any },
    slots: { number },
    was: { [number]: number },
    at: { number },
    count: number
) -> number

-- Private -------------------------------------------------------------

local function reject (code: Catalog.Code, tag: Ir.Tag, got: any): never
    return Log.reject (code, { pathId = tag.pathId, expectId = tag.expectId, got = got })
end

-- Public --------------------------------------------------------------

-- A field whose values are points on a grid, as one packed run of their indices.
function Column.grid (
    tag: Ir.Tag,
    paths: Serial.Interner,
    expected: Serial.Interner,
    of: Grid.Grid
): (Write, Read)
    local toIndex, fromIndex = of.toIndex, of.fromIndex
    local toIndices, fromIndices = of.toIndices, of.fromIndices
    local width, span = of.width, of.span

    --[[
        A column is one field across every slot holding it, which is a run and not a value. What a
        grid will take or hand back for a whole run at once it does cheaper that way, both halves
        alike, and a grid that is its own index has nothing the taking half needs to ask it for.
    ]]
    local plain = of.plain == true

    --[[
        Whether every pattern the width spells is a point the grid has, so nothing off the bytes is
        over its top. A grid that is its own index as well leaves a run with no reading to work out
        and none to turn away, which is a copy and not a walk.
    ]]
    local whole = of.whole == true

    local function write (
        b: buffer,
        pos: number,
        from: { any },
        at: { number },
        count: number
    ): number
        if toIndices ~= nil then
            local off = toIndices (from, at, count)
            if off ~= nil then Word.refusedAt (tag, paths, expected, from[off]) end
        else
            for place = 1, count do
                local one = toIndex (from[place])
                if one == nil then Word.refusedAt (tag, paths, expected, from[place]) end

                at[place] = one :: number
            end
        end

        return PACKED (b, pos, width, count, at)
    end

    local function read (
        b: buffer,
        pos: number,
        into: { any },
        at: { number },
        count: number,
        _ctx: Types.ValidateContext
    ): number
        local after, clean = UNPACKED (b, pos, width, count, at)
        if not clean then reject (Catalog.PAD, tag, count) end

        --[[
            Held to the grid by its own width, so nothing off the bytes is off the grid and the
            run goes back whole. A grid that cannot say that is walked below a reading at a time,
            since what turns a run back says nothing about whether it should have.
        ]]
        if whole and fromIndices ~= nil then
            fromIndices (at, into, count)
            return after
        end

        if plain then
            if whole then
                table.move (at, 1, count, 1, into)
                return after
            end

            for place = 1, count do
                local one = at[place]
                if one > span then reject (Catalog.TAG, tag, one) end

                into[place] = one
            end

            return after
        end

        if whole then
            for place = 1, count do
                into[place] = fromIndex (at[place])
            end

            return after
        end

        for place = 1, count do
            local one = at[place]
            if one > span then reject (Catalog.TAG, tag, one) end

            into[place] = fromIndex (one)
        end

        return after
    end

    return write, read
end

--[[
    A run of the small numbers the protocol names for itself, which is a delta's presence run and a
    keyframe's generations. Every pattern of the width is a value, so the only thing this can turn
    away is a pad. It carries a phrase rather than a tag, because neither number is at a place in a
    schema and a rejection would name a path out of whichever field's table was reached for.
]]
function Column.bits (width: number, said: string): (Write, Read)
    local function write (
        b: buffer,
        pos: number,
        from: { any },
        _at: { number },
        count: number
    ): number
        return PACKED (b, pos, width, count, from :: any)
    end

    local function read (
        b: buffer,
        pos: number,
        into: { any },
        _at: { number },
        count: number,
        _ctx: Types.ValidateContext
    ): number
        local after, clean = UNPACKED (b, pos, width, count, into :: any)
        if not clean then Log.reject (Catalog.SECTION, { said = said }) end

        return after
    end

    return write, read
end

-- A field that is no run, as its own pair called once per record.
local function apiece (writeOne: Ir.Write, readOne: Ir.Read): (Write, Read)
    local function write (
        b: buffer,
        pos: number,
        from: { any },
        _at: { number },
        count: number
    ): number
        local at = pos
        for place = 1, count do
            at = writeOne (b, at, from[place])
        end
        return at
    end

    local function read (
        b: buffer,
        pos: number,
        into: { any },
        _at: { number },
        count: number,
        ctx: Types.ValidateContext
    ): number
        local at = pos
        for place = 1, count do
            at, into[place] = readOne (b, at, ctx)
        end
        return at
    end

    return write, read
end

-- The same field, stating where each of its values sits on its grid.
local function stated (writeOne: Ir.Write, readOne: Ir.Read, of: Grid.Grid): (Write, Read)
    local toIndex = of.toIndex

    local function write (
        b: buffer,
        pos: number,
        from: { any },
        at: { number },
        count: number
    ): number
        local held = pos
        for place = 1, count do
            local one = from[place]
            held = writeOne (b, held, one)
            at[place] = toIndex (one) :: number
        end
        return held
    end

    local function read (
        b: buffer,
        pos: number,
        into: { any },
        at: { number },
        count: number,
        ctx: Types.ValidateContext
    ): number
        local held = pos
        for place = 1, count do
            local one: any
            held, one = readOne (b, held, ctx)

            into[place] = one
            at[place] = toIndex (one) :: number
        end
        return held
    end

    return write, read
end

-- Whichever of the two above the field wants, which is the stated one wherever it has a grid.
function Column.each (writeOne: Ir.Write, readOne: Ir.Read, of: Grid.Grid?): (Write, Read)
    if of == nil then return apiece (writeOne, readOne) end
    return stated (writeOne, readOne, of)
end

--[[
    A field against what the other machine already holds, as one varint of the difference each. The
    guess is the caller's, since a last value and an extrapolation differ only in how they are
    computed. A slot with no baseline is one this receiver does not hold, and its element is read
    for its width and dropped.
]]
function Column.gain (
    tag: Ir.Tag,
    paths: Serial.Interner,
    expected: Serial.Interner,
    of: Grid.Grid,
    signed: boolean
): (Gain, Regain)
    local toIndex, fromIndex = of.toIndex, of.fromIndex
    local fromIndices = of.fromIndices
    local span = of.span

    --[[
        Whether a grid hands back the index it was given, which the walk below asks once a run
        rather than paying a call an element for an answer it already holds.
    ]]
    local plain = of.plain == true

    local points = if of.wrap then span + 1 else 0
    local half = if signed then points // 2 else 0

    local putRun = if signed then Varint.writeSignedRun else Varint.writeRun
    local takeRun = if signed then Varint.readSignedRun else Varint.readRun

    -- Made once and filled over, no reading of a section outliving the walk that took it.
    local steps: { number } = {}

    local function write (
        b: buffer,
        pos: number,
        from: { any },
        slots: { number },
        was: { [number]: number },
        at: { number },
        count: number
    ): number
        -- What the walk asks of the grid and of the turn, reached once rather than once a step.
        local toIndex, points, half, steps = toIndex, points, half, steps

        for place = 1, count do
            local one = toIndex (from[place])
            if one == nil then Word.refusedAt (tag, paths, expected, from[place]) end

            local now = one :: number
            local step = now - was[slots[place]]
            if points > 0 then step = (step + half) % points - half end

            at[place] = now
            steps[place] = step
        end

        --[[
            Every step of the section down in one crossing, once all of them are worked out. A step
            is a number and nothing about where it lands, so the section is laid whole and the walk
            above is left with the grid alone to answer to.
        ]]
        return putRun (b, pos, steps, count)
    end

    local function walk (
        b: buffer,
        pos: number,
        into: { any },
        slots: { number },
        was: { [number]: number },
        at: { number },
        count: number
    ): number
        -- What the walk reaches at every element, taken once: the steps, the bounds, the pair.
        local steps, span, points = steps, span, points
        local fromIndices, fromIndex = fromIndices, fromIndex

        --[[
            Every step of the section off the bytes before any of them is put back on the grid. A
            step stands on its own, needing neither the slot it belongs to nor the one before it,
            so the crossing into the varints is paid once for the section and not once a step.
        ]]
        local held = takeRun (b, pos, steps, count)

        if plain then
            for place = 1, count do
                local base = was[slots[place]]
                if base == nil then continue end

                local one = base + steps[place]
                if points > 0 then
                    one %= points
                end
                if not (one >= 0 and one <= span) then reject (Catalog.TAG, tag, one) end

                at[place] = one
                into[place] = one
            end

            return held
        end

        --[[
            A slot this receiver does not hold, met anywhere along the section. Every reading is
            held to the grid on the way past either way, and this only settles whether the run can
            go back to the caller in one piece afterwards or has to be picked over.
        ]]
        local missed = false

        for place = 1, count do
            local base = was[slots[place]]
            if base == nil then
                missed = true
                continue
            end

            local now = base + steps[place]
            if points > 0 then
                now %= points
            end
            if not (now >= 0 and now <= span) then reject (Catalog.TAG, tag, now) end

            at[place] = now
            if fromIndices == nil then into[place] = fromIndex (now) end
        end

        if fromIndices == nil then return held end

        --[[
            The whole section turned back at once, every reading in it having been held to the grid
            above. A section that skipped a slot has an older reading of its own standing where that
            slot fell, so that one is picked over instead of handed across as it stands.
        ]]
        if not missed then
            fromIndices (at, into, count)
            return held
        end

        for place = 1, count do
            if was[slots[place]] ~= nil then into[place] = fromIndex (at[place]) end
        end

        return held
    end

    local function read (
        b: buffer,
        pos: number,
        into: { any },
        slots: { number },
        was: { [number]: number },
        at: { number },
        count: number
    ): number
        local ok, after = pcall (walk, b, pos, into, slots, was, at, count)
        if ok then return after :: number end

        -- A rejection from deeper in, rethrown as it stands rather than read as a varint fault.
        if typeof (after) == "table" then error (after, 0) end
        return reject (Catalog.VARINT, tag, after)
    end

    return write, read
end

return table.freeze (Column)
