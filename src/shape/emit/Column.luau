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
    local fromIndices = of.fromIndices
    local width, span = of.width, of.span

    --[[
        A column is one field across every slot holding it, which is a run and not a value. What a
        grid can hand back for a whole run at once it hands back cheaper that way, and a grid that
        is its own index has nothing the taking half needs to ask it for at all.
    ]]
    local plain = of.plain == true

    local function write (
        b: buffer,
        pos: number,
        from: { any },
        at: { number },
        count: number
    ): number
        for place = 1, count do
            local one = toIndex (from[place])
            if one == nil then Word.refusedAt (tag, paths, expected, from[place]) end

            at[place] = one :: number
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

        if fromIndices ~= nil then
            fromIndices (at, into, count)
            return after
        end

        if plain then
            for place = 1, count do
                local one = at[place]
                if one > span then reject (Catalog.TAG, tag, one) end

                into[place] = one
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

--[[
    A field that is no run, as its own pair called once per record, and saying nothing about where
    its values sit on a grid.
]]
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

--[[
    A field that is no run, as its own pair called once per record, which is a constant stride when
    the field is a byte field and whatever the field is otherwise.
]]
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
    local span = of.span

    local points = if of.wrap then span + 1 else 0
    local half = if signed then points // 2 else 0

    local put = if signed then Varint.writeSigned else Varint.write
    local take = if signed then Varint.readSigned else Varint.read

    local function write (
        b: buffer,
        pos: number,
        from: { any },
        slots: { number },
        was: { [number]: number },
        at: { number },
        count: number
    ): number
        local held = pos

        for place = 1, count do
            local one = toIndex (from[place])
            if one == nil then Word.refusedAt (tag, paths, expected, from[place]) end

            local now = one :: number
            local step = now - was[slots[place]]
            if points > 0 then step = (step + half) % points - half end

            at[place] = now
            held = put (b, held, step)
        end

        return held
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
        local held = pos

        for place = 1, count do
            local step, after = take (b, held)
            held = after

            local base = was[slots[place]]
            if base == nil then continue end

            local now = base + step
            if points > 0 then
                now %= points
            end
            if not (now >= 0 and now <= span) then reject (Catalog.TAG, tag, now) end

            at[place] = now
            into[place] = fromIndex (now)
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

        -- Passed along rather than raised again, which is why it does not take the door.
        if typeof (after) == "table" then error (after, 0) end
        return reject (Catalog.VARINT, tag, after)
    end

    return write, read
end

return table.freeze (Column)
