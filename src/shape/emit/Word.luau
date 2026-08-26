--!strict
--!native
--!optimize 2
-- One bit region, as the pair of closures that lay it down and take it back up.

local Catalog = require ("@src/kernel/Catalog")
local Ir = require ("@src/shape/Ir")
local Log = require ("@src/kernel/Log")
local Serial = require ("@src/shape/Serial")
local Words = require ("@src/shape/Words")

local Word = {}

-- Constants -----------------------------------------------------------

-- The same two widths a frame header reads, a region and a header being one kind of bit run.
const ONE = Words.ONE
const PAIR = Words.PAIR

-- Types ---------------------------------------------------------------

-- The two halves of a region, and the array of indices they meet in.
export type Pack = (b: buffer, pos: number, value: any, slots: { number }, holds: { any }) -> ()
export type Unpack = (b: buffer, pos: number, into: any, slots: { number }, holds: { any }) -> any

-- Public --------------------------------------------------------------

-- A value the schema has no place for, refused in the words a caller wrote.
function Word.refused (path: string, wanted: string, got: any): never
    return Log.refuse (
        Log.line (Catalog.TAG, { path = path, expected = wanted, got = tostring (got) })
    )
end

--[[
    The same refusal from a tag, which is what a composite carries in place of the words.

    A leaf holds its own and a composite holds the numbers they were interned under, so the lookup
    is the half that differs and this is where the two meet.
]]
function Word.refusedAt (
    tag: Ir.Tag,
    paths: Serial.Interner,
    said: Serial.Interner,
    got: any
): never
    return Word.refused (paths.texts[tag.pathId], said.texts[tag.expectId], got)
end

-- The pair, with every constant the region is laid out by read once and held.
function Word.emit (of: Ir.Word, paths: Serial.Interner, expected: Serial.Interner): (Pack, Unpack)
    local leaves = of.leaves
    local joins = of.joins
    local held = #leaves

    -- Per leaf, in wire order.
    local spans = table.create (held, 0)
    local toIndex = table.create (held) :: { (number) -> number? }
    local fromIndex = table.create (held) :: { (number) -> number }

    -- The leaves whose value is the index, which are read back without reaching for the mapping.
    local plain = table.create (held, false) :: { boolean }

    -- The leaves that fill their bits, which no reading can carry off the grid.
    local whole = table.create (held, false) :: { boolean }

    for index, grid in leaves do
        spans[index] = grid.span
        toIndex[index] = grid.toIndex
        fromIndex[index] = grid.fromIndex
        plain[index] = grid.plain == true
        whole[index] = grid.whole == true
    end

    -- The leaves that occupy no bits, which is every grid holding one value.
    local empties: { number } = {}
    for index = 1, held do
        if spans[index] == 0 then table.insert (empties, index) end
    end

    -- Per join, in the order the region reads its fields.
    local reach = #joins
    local starts = table.create (reach, 0)
    local ends = table.create (reach, 0)
    local keys = table.create (reach) :: { string? }
    local inside = table.create (reach, 0)
    local pulls = table.create (reach) :: { ((any, { number }, number) -> boolean)? }
    local pushes = table.create (reach) :: { (({ number }, number) -> any)? }
    local wheres = table.create (reach) :: { string }
    local wanted = table.create (reach) :: { string }

    --[[
        Whether a field has a reading that could be off its grid. Where none of its leaves does,
        the walk that would look is one nothing can find anything in.
    ]]
    local watched = table.create (reach, false) :: { boolean }

    for index, join in joins do
        starts[index] = join.at
        ends[index] = join.at + join.count - 1
        keys[index] = join.key
        inside[index] = join.nest or 0
        pulls[index] = join.pull
        pushes[index] = join.push
        wheres[index] = paths.texts[join.tag.pathId]
        wanted[index] = expected.texts[join.tag.expectId]

        for leaf = join.at, join.at + join.count - 1 do
            if whole[leaf] then continue end
            watched[index] = true
            break
        end
    end

    -- Per window, and then the parts of every window end to end.
    local plan = of.plan
    local windows = #plan
    local width = table.create (windows, 0)
    local where = table.create (windows, 0)
    local first = table.create (windows, 0)
    local last = table.create (windows, 0)

    local slot: { number } = {}
    local offset: { number } = {}
    local span: { number } = {}
    local shift: { number } = {}

    for index, window in plan do
        width[index] = window.bytes
        where[index] = window.at
        first[index] = #slot + 1

        for _, part in window.parts do
            table.insert (slot, part.field)
            table.insert (offset, part.offset)
            table.insert (span, part.width)
            table.insert (shift, part.shift)
        end

        last[index] = #slot
    end

    --[[
        Every field to its index, then every window to its bytes. In that order rather than one
        pass, because a field can straddle two windows and a window can hold pieces of fields that
        are nowhere near each other in the record.
    ]]
    local function pack (b: buffer, pos: number, value: any, slots: { number }, held: { any })
        for index = 1, reach do
            local key = keys[index]
            local within = inside[index]
            local from = if within == 0 then value else held[within]

            local one = if key == nil then from else from[key]
            local pull = pulls[index]

            if pull == nil then
                local at = starts[index]
                local made = toIndex[at] (one)
                if made == nil then Word.refused (wheres[index], wanted[index], one) end

                slots[at] = made :: number
                continue
            end

            if not pull (one, slots, starts[index]) then
                Word.refused (wheres[index], wanted[index], one)
            end
        end

        for index = 1, windows do
            local acc = 0
            for part = first[index], last[index] do
                local piece = bit32.extract (slots[slot[part]], shift[part], span[part])
                acc = bit32.bor (acc, bit32.lshift (piece, offset[part]))
            end

            local at = pos + where[index]
            local bytes = width[index]
            if bytes == ONE then
                buffer.writeu8 (b, at, acc)
            elseif bytes == PAIR then
                buffer.writeu16 (b, at, acc)
            else
                buffer.writeu32 (b, at, acc)
            end
        end
    end

    --[[
        Every window to its pieces, then every field to its value. A piece at no shift is written
        rather than merged, because what is under it is whatever the last call through this region
        left there, and a field that straddles two windows meets its low piece first.
    ]]
    local function unpack (b: buffer, pos: number, into: any, slots: { number }, held: { any }): any
        for _, leaf in empties do
            slots[leaf] = 0
        end

        for index = 1, windows do
            local at = pos + where[index]
            local bytes = width[index]
            local acc = if bytes == ONE
                then buffer.readu8 (b, at)
                elseif bytes == PAIR then buffer.readu16 (b, at)
                else buffer.readu32 (b, at)

            for part = first[index], last[index] do
                local piece = bit32.extract (acc, offset[part], span[part])
                local up = shift[part]
                if up == 0 then
                    slots[slot[part]] = piece
                    continue
                end
                slots[slot[part]] = bit32.bor (slots[slot[part]], bit32.lshift (piece, up))
            end
        end

        local bare: any = nil

        for index = 1, reach do
            if watched[index] then
                for leaf = starts[index], ends[index] do
                    if slots[leaf] <= spans[leaf] then continue end

                    -- Held back to here, since a decode that holds never has a tag to report.
                    local tag = joins[index].tag
                    Log.reject (Catalog.TAG, {
                        pathId = tag.pathId,
                        expectId = tag.expectId,
                        got = slots[leaf],
                    })
                end
            end

            local push = pushes[index]
            local at = starts[index]
            local one: any
            if push ~= nil then
                one = push (slots, at)
            elseif plain[at] then
                one = slots[at]
            else
                one = fromIndex[at] (slots[at])
            end

            local key = keys[index]
            if key == nil then
                bare = one
                continue
            end

            local within = inside[index]
            local up = if within == 0 then into else held[within]
            up[key] = one
        end

        return bare
    end

    return pack, unpack
end

return table.freeze (Word)
