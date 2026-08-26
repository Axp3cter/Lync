--!strict
--!native
--!optimize 2
-- One bit region, as the pair of closures that lay it down and take it back up.

local Catalog = require ("@src/kernel/Catalog")
local Ir = require ("@src/shape/Ir")
local Log = require ("@src/kernel/Log")
local Protocol = require ("@src/wire/Protocol")
local Serial = require ("@src/shape/Serial")
local Words = require ("@src/shape/Words")

local Word = {}

-- Constants -----------------------------------------------------------

-- The same two widths a frame header reads, a region and a header being one kind of bit run.
const ONE = Words.ONE

-- How many bits a byte holds, which is what turns a field's width into the call that writes it.
const BYTE = Protocol.BYTE_BITS
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
    --[[
        The reading each leaf needs, and nothing at all for the leaves whose value is already the
        index. Absence rather than a second array beside this one, since a decode then asks one
        question where it used to ask two and the answer to the first was almost always no.
    ]]
    local fromIndex = table.create (held) :: { ((number) -> any)? }

    -- The leaves that fill their bits, which no reading can carry off the grid.
    local whole = table.create (held, false) :: { boolean }

    for index, grid in leaves do
        spans[index] = grid.span
        toIndex[index] = grid.toIndex
        fromIndex[index] = if grid.plain == true then nil else grid.fromIndex
        whole[index] = grid.whole == true
    end

    -- The leaves that occupy no bits, which is every grid holding one value.
    local empties: { number } = {}
    for index = 1, held do
        if spans[index] == 0 then table.insert (empties, index) end
    end

    -- Whether there are any, since a walk over none is one a decode takes for nothing.
    local barren = #empties > 0

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

    for index, join in joins do
        starts[index] = join.at
        keys[index] = join.key
        inside[index] = join.nest or 0
        pulls[index] = join.pull
        pushes[index] = join.push
        wheres[index] = paths.texts[join.tag.pathId]
        wanted[index] = expected.texts[join.tag.expectId]

        --[[
            The last leaf a bounds walk looks at, and one short of the first where every leaf of
            the field fills its bits. A walk over nothing is then a loop declining to run, rather
            than a question asked of every field on every frame to be told no.
        ]]
        local upto = join.at - 1
        for leaf = join.at, join.at + join.count - 1 do
            if whole[leaf] then continue end
            upto = join.at + join.count - 1
            break
        end

        ends[index] = upto
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

    --[[
        Whether a piece is the whole of the reading it comes from. A field wide enough to straddle
        two windows arrives as two pieces and each has to be cut out of it, and a field that fits
        one is already the piece, so cutting it out asks for every bit it already has.
    ]]
    local direct: { boolean } = {}

    for index, window in plan do
        width[index] = window.bytes
        where[index] = window.at
        first[index] = #slot + 1

        for _, part in window.parts do
            table.insert (slot, part.field)
            table.insert (offset, part.offset)
            table.insert (span, part.width)
            table.insert (shift, part.shift)
            table.insert (
                direct,
                part.shift == 0 and bit32.lshift (1, part.width) - 1 >= spans[part.field]
            )
        end

        last[index] = #slot
    end

    --[[
        Whether every field of this word is its own whole reading and sits on the record itself.
        Where that holds of one field it holds of all of them, so the two arrays saying so answer
        the same both times, and a word that asks them once asks them a field fewer than it has.
    ]]
    local simple = true
    for index = 1, reach do
        if pulls[index] ~= nil or pushes[index] ~= nil or inside[index] ~= 0 then
            simple = false
            break
        end
    end

    --[[
        Every field to its index, then every window to its bytes. In that order rather than one
        pass, because a field can straddle two windows and a window can hold pieces of fields that
        are nowhere near each other in the record.
    ]]
    local function pack (b: buffer, pos: number, value: any, slots: { number }, held: { any })
        if simple then
            for index = 1, reach do
                local key = keys[index]
                local one = if key == nil then value else value[key]
                local at = starts[index]
                local made = toIndex[at] (one)
                if made == nil then Word.refused (wheres[index], wanted[index], one) end

                slots[at] = made :: number
            end
        else
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
        end

        for index = 1, windows do
            local acc = 0
            for part = first[index], last[index] do
                local cell = slot[part]
                local piece = if direct[part]
                    then slots[cell]
                    else bit32.extract (slots[cell], shift[part], span[part])

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
        if barren then
            for _, leaf in empties do
                slots[leaf] = 0
            end
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
            local at = starts[index]

            for leaf = at, ends[index] do
                if slots[leaf] <= spans[leaf] then continue end

                -- Held back to here, since a decode that holds never has a tag to report.
                local tag = joins[index].tag
                Log.reject (Catalog.TAG, {
                    pathId = tag.pathId,
                    expectId = tag.expectId,
                    got = slots[leaf],
                })
            end

            local key = keys[index]

            local one: any
            if simple then
                local reading = fromIndex[at]
                one = if reading == nil then slots[at] else reading (slots[at])

                if key == nil then
                    bare = one
                else
                    into[key] = one
                end
                continue
            end

            local push = pushes[index]
            if push ~= nil then
                one = push (slots, at)
            else
                local reading = fromIndex[at]
                one = if reading == nil then slots[at] else reading (slots[at])
            end

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

    --[[
        Every field in one piece, wherever the windows put them, where the pair above walks a
        scratch array between the fields and the bytes for a value that never leaves the call. A
        piece a field is the whole of what that asks: a cut one has a piece shifted up it and a
        piece that is not its whole reading, and counting pieces settles both at once.
    ]]
    if simple and #slot == reach and reach > 1 then
        -- Which field each piece belongs to, by the piece, since a window walks its own.
        local whose = table.create (held, 0)
        for index = 1, reach do
            whose[starts[index]] = index
        end

        --[[
            What each piece needs, by the piece. A window walks pieces and every one of these is
            held by the leaf its field starts at, so a walk that does not gather them first steps
            through that number for each, where the number is settled once the word is built.
        ]]
        local owner = table.create (#slot, 0)
        local puts = table.create (#slot) :: { string }
        local makes = table.create (#slot) :: { (number) -> number? }
        local takes = table.create (#slot) :: { ((number) -> any)? }
        local tops = table.create (#slot, 0)
        local fills = table.create (#slot, false)

        for part = 1, #slot do
            local cell = slot[part]
            local index = whose[cell]

            owner[part] = index
            puts[part] = keys[index] :: string
            makes[part] = toIndex[cell]
            takes[part] = fromIndex[cell]
            tops[part] = spans[cell]
            fills[part] = whole[cell]
        end

        --[[
            Whether every field starts on a byte and is as wide as one call the engine has. A
            window gathers the fields that share a byte, and fields that share none have nothing
            to gather: a field on a boundary is already one of the bytes a window would write.
        ]]
        local seats = table.create (reach, 0)
        local sizes = table.create (reach, 0)
        local upright = true

        for window = 1, windows do
            for part = first[window], last[window] do
                -- One piece a field is settled above, and a leaf is capped well under four bytes.
                local bits = span[part]
                local wide = if bits == BYTE * ONE
                    then ONE
                    elseif bits == BYTE * PAIR then PAIR
                    else 0

                if wide == 0 then
                    upright = false
                    break
                end

                local index = whose[slot[part]]
                seats[index] = where[window] + offset[part] // BYTE
                sizes[index] = wide
            end

            if not upright then break end
        end

        local function flat (b: buffer, pos: number, value: any, _s: { number }, _h: { any })
            for window = 1, windows do
                local acc = 0

                for part = first[window], last[window] do
                    local one = value[puts[part]]
                    local made = makes[part] (one)
                    if made == nil then
                        local index = owner[part]
                        Word.refused (wheres[index], wanted[index], one)
                    end

                    acc = bit32.bor (acc, bit32.lshift (made :: number, offset[part]))
                end

                local at = pos + where[window]
                local bytes = width[window]
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
            The same, taken back up. A field with no key is an optional standing on its own, which
            is a single field reached through a pull, and both of those are settled above, so every
            piece here has a key to be put under and neither half asks whether it does.
        ]]
        local function level (b: buffer, pos: number, into: any, _s: { number }, _h: { any }): any
            for window = 1, windows do
                local at = pos + where[window]
                local bytes = width[window]
                local acc = if bytes == ONE
                    then buffer.readu8 (b, at)
                    elseif bytes == PAIR then buffer.readu16 (b, at)
                    else buffer.readu32 (b, at)

                for part = first[window], last[window] do
                    local raw = bit32.extract (acc, offset[part], span[part])

                    if not fills[part] and raw > tops[part] then
                        local tag = joins[owner[part]].tag
                        Log.reject (Catalog.TAG, {
                            pathId = tag.pathId,
                            expectId = tag.expectId,
                            got = raw,
                        })
                    end

                    local reading = takes[part]
                    into[puts[part]] = if reading == nil then raw else reading (raw)
                end
            end

            return nil
        end

        --[[
            What each field needs, by the field. The arrays above are held by the leaf a field
            starts at, so reaching one costs a step through that number every time a word runs,
            where the number itself never changes after the word is built.
        ]]
        local writes = table.create (reach) :: { (number) -> number? }
        local readings = table.create (reach) :: { ((number) -> any)? }
        local bounds = table.create (reach, 0)
        local checks = table.create (reach, false)

        for index = 1, reach do
            local cell = starts[index]
            writes[index] = toIndex[cell]
            readings[index] = fromIndex[cell]
            bounds[index] = spans[cell]
            checks[index] = not whole[cell]
        end

        --[[
            Whether every field's grid runs from nothing in whole steps, where a whole number
            already inside it is its own index. Recognising that is not a second copy of the
            rounding: anything the test below does not settle is still handed to the one grid.
        ]]
        local plainly = upright
        for index = 1, reach do
            if leaves[starts[index]].plain == true then continue end

            plainly = false
            break
        end

        -- Whether a read does anything past taking the bytes, which for a full grid it does not.
        local bluntly = plainly
        for index = 1, reach do
            if not checks[index] then continue end

            bluntly = false
            break
        end

        --[[
            Whether every field is one byte and sits on the byte after the one before it. A word
            laid out that way needs no seat kept for it: the seat is the step, so a walk that
            counts as it goes reaches each field where it is without being told where that is.
        ]]
        local singly = upright
        for index = 1, reach do
            if sizes[index] == ONE and seats[index] == index - 1 then continue end

            singly = false
            break
        end

        if singly then
            -- The same pair where every field is one byte, so which call to make is not a question.
            local function steady (b: buffer, pos: number, value: any, _s: { number }, _h: { any })
                local at = pos
                for index = 1, reach do
                    local one = value[keys[index]]
                    local made = writes[index] (one)
                    if made == nil then Word.refused (wheres[index], wanted[index], one) end

                    buffer.writeu8 (b, at, made :: number)
                    at += 1
                end
            end

            -- The same, where a whole number already on the grid is the index and asks nothing.
            local function ready (b: buffer, pos: number, value: any, _s: { number }, _h: { any })
                local at = pos
                for index = 1, reach do
                    local one = value[keys[index]]
                    local made = one

                    if type (one) ~= "number" or one % 1 ~= 0 or one < 0 or one > bounds[index] then
                        made = writes[index] (one)
                        if made == nil then Word.refused (wheres[index], wanted[index], one) end
                    end

                    buffer.writeu8 (b, at, made :: number)
                    at += 1
                end
            end

            local function settled (
                b: buffer,
                pos: number,
                into: any,
                _s: { number },
                _h: { any }
            ): any
                local at = pos
                for index = 1, reach do
                    local raw = buffer.readu8 (b, at)
                    at += 1

                    if checks[index] and raw > bounds[index] then
                        local tag = joins[index].tag
                        Log.reject (Catalog.TAG, {
                            pathId = tag.pathId,
                            expectId = tag.expectId,
                            got = raw,
                        })
                    end

                    local reading = readings[index]
                    into[keys[index]] = if reading == nil then raw else reading (raw)
                end

                return nil
            end

            -- The same read where every grid fills its bits, so a byte is the value it stands for.
            local function blunt (
                b: buffer,
                pos: number,
                into: any,
                _s: { number },
                _h: { any }
            ): any
                local at = pos
                for index = 1, reach do
                    into[keys[index]] = buffer.readu8 (b, at)
                    at += 1
                end

                return nil
            end

            if bluntly then return ready, blunt end
            if plainly then return ready, settled end

            return steady, settled
        end

        if upright then
            --[[
                Every field straight to its own bytes. The one definition making a field with no
                key is an optional standing alone, which is a single field reached through a pull,
                and both of those are settled above, so every field here has one to be put under.
            ]]
            local function square (b: buffer, pos: number, value: any, _s: { number }, _h: { any })
                for index = 1, reach do
                    local one = value[keys[index]]
                    local made = writes[index] (one)
                    if made == nil then Word.refused (wheres[index], wanted[index], one) end

                    local at = pos + seats[index]
                    if sizes[index] == ONE then
                        buffer.writeu8 (b, at, made :: number)
                    else
                        buffer.writeu16 (b, at, made :: number)
                    end
                end
            end

            -- The same bytes back, each read where it lies rather than cut out of a window.
            local function upward (
                b: buffer,
                pos: number,
                into: any,
                _s: { number },
                _h: { any }
            ): any
                for index = 1, reach do
                    local at = pos + seats[index]
                    local raw = if sizes[index] == ONE
                        then buffer.readu8 (b, at)
                        else buffer.readu16 (b, at)

                    if checks[index] and raw > bounds[index] then
                        local tag = joins[index].tag
                        Log.reject (Catalog.TAG, {
                            pathId = tag.pathId,
                            expectId = tag.expectId,
                            got = raw,
                        })
                    end

                    local reading = readings[index]
                    into[keys[index]] = if reading == nil then raw else reading (raw)
                end

                return nil
            end

            return square, upward
        end

        return flat, level
    end

    --[[
        One field in one window, which is what a bare number is and what every key and value of a
        map are. The loops above walk arrays to find what is already known here, so the same work
        is the reading, the bounds and the one write, with nothing looked up to reach them.
    ]]
    if
        reach == 1
        and windows == 1
        and first[1] == last[1]
        and pulls[1] == nil
        and pushes[1] == nil
        and direct[1]
        and offset[1] == 0
        and inside[1] == 0
    then
        local key = keys[1]
        local cell = starts[1]
        local edge = ends[1]
        local reading = fromIndex[cell]
        local writing = toIndex[cell]
        local bound = spans[cell]
        local said, want = wheres[1], wanted[1]
        local seat, bytes = where[1], width[1]
        local sign = joins[1].tag
        local named, meant = sign.pathId, sign.expectId

        local function only (b: buffer, pos: number, value: any, slots: { number }, _held: { any })
            local one = if key == nil then value else value[key]
            local made = writing (one)
            if made == nil then Word.refused (said, want, one) end

            local at = pos + seat
            if bytes == ONE then
                buffer.writeu8 (b, at, made :: number)
            elseif bytes == PAIR then
                buffer.writeu16 (b, at, made :: number)
            else
                buffer.writeu32 (b, at, made :: number)
            end
        end

        local function sole (
            b: buffer,
            pos: number,
            into: any,
            slots: { number },
            _held: { any }
        ): any
            local at = pos + seat
            local raw = if bytes == ONE
                then buffer.readu8 (b, at)
                elseif bytes == PAIR then buffer.readu16 (b, at)
                else buffer.readu32 (b, at)

            if edge >= cell and raw > bound then
                Log.reject (Catalog.TAG, { pathId = named, expectId = meant, got = raw })
            end

            local one = if reading == nil then raw else reading (raw)
            if key == nil then return one end

            into[key] = one
            return nil
        end

        return only, sole
    end

    return pack, unpack
end

return table.freeze (Word)
