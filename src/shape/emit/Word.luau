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

--[[
    A top no reading stands under, which is what a piece carries where recognising one would cost
    more than asking its grid. Every number is above it, so the recognition settles nothing and
    the one grid answers, which is what a grid not running from nothing in whole steps needs.
]]
const UNDER_ALL = -1

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
function Word.emit (
    of: Ir.Word,
    paths: Serial.Interner,
    expected: Serial.Interner
): (Pack, Unpack, Ir.Read?)
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

    --[[
        Every leaf a bound is read against, and the field owning it, as one run. A field whose
        leaves all fill their bits puts nothing here, so a word of those is a run of nothing at
        all rather than a walk declining to look once a field it holds.
    ]]
    local watched: { number } = {}
    local watcher: { number } = {}

    for index = 1, reach do
        for leaf = starts[index], ends[index] do
            table.insert (watched, leaf)
            table.insert (watcher, index)
        end
    end

    local watching = #watched

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
        Whether every field is its own whole reading, sits on the record itself, and carries a
        name of its own. The one without a name is an optional standing alone, which the walk for
        the rest reaches the same way. Such a field holds one leaf and the leaves lie in the order
        the fields do, so its seat is its own number and neither half below looks either one up.
    ]]
    local simple = true
    for index = 1, reach do
        if
            pulls[index] ~= nil
            or pushes[index] ~= nil
            or inside[index] ~= 0
            or keys[index] == nil
        then
            simple = false
            break
        end
    end

    --[[
        Whether every field's grid runs from nothing in whole steps. Recognising a reading already
        on such a grid is not a second copy of the rounding, since anything the recognition does
        not settle is still handed to the one grid to settle.
    ]]
    local flatly = simple
    for index = 1, reach do
        local grid = leaves[starts[index]]
        if grid ~= nil and grid.plain == true then continue end

        flatly = false
        break
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
        Every field to its index, then every window to its bytes. In that order rather than one
        pass, because a field can straddle two windows and a window can hold pieces of fields that
        are nowhere near each other in the record.
    ]]
    local function pack (b: buffer, pos: number, value: any, slots: { number }, held: { any })
        --[[
            The arrays the window walk reads, reached once for the walk. Each of them is a table
            this closure was built over, so naming one at every piece asks the closure for it as
            many times as the word has pieces, where the walk wants it as many times as it runs.
        ]]
        local first, last, slot, span, shift, direct = first, last, slot, span, shift, direct
        local where, width = where, width

        if flatly then
            for index, key in keys do
                local one = value[key]
                local made = one

                if type (one) ~= "number" or bit32.bor (one, 0) ~= one or one > bounds[index] then
                    made = writes[index] (one)
                    if made == nil then Word.refused (wheres[index], wanted[index], one) end
                end

                slots[index] = made :: number
            end
        elseif simple then
            for index, key in keys do
                local one = value[key]
                local at = index
                local made = writes[index] (one)
                if made == nil then Word.refused (wheres[index], wanted[index], one) end

                slots[at] = made :: number
            end
        else
            local keys, writes, wheres, wanted = keys, writes, wheres, wanted
            local inside, pulls, starts = inside, pulls, starts

            for index = 1, reach do
                local key = keys[index]

                local within = inside[index]
                local from = if within == 0 then value else held[within]

                local one = if key == nil then from else from[key]
                local pull = pulls[index]

                if pull == nil then
                    local at = starts[index]
                    local made = writes[index] (one)
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
            local head = first[index]
            local cell = slot[head]

            --[[
                A window is filled from its low bit up, so its first piece sits at no offset and is
                what the rest are merged into. Merging it as well would shift it by nothing and or
                it onto nothing, which is two calls a window that answer with what went in.
            ]]
            local acc = if direct[head]
                then slots[cell]
                else bit32.extract (slots[cell], shift[head], span[head])

            for part = head + 1, last[index] do
                local pick = slot[part]
                local piece = if direct[part]
                    then slots[pick]
                    else bit32.extract (slots[pick], shift[part], span[part])

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
        local first, last, slot, span, shift, offset = first, last, slot, span, shift, offset
        local where, width = where, width

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
                local cell = slot[part]
                local piece = bit32.extract (acc, offset[part], span[part])

                local up = shift[part]
                if up == 0 then
                    slots[cell] = piece
                    continue
                end

                slots[cell] = bit32.bor (slots[cell], bit32.lshift (piece, up))
            end
        end

        local bare: any = nil

        -- Every reading held to its grid before any of them is handed on, whatever the word is.
        for spot = 1, watching do
            local leaf = watched[spot]
            if slots[leaf] <= spans[leaf] then continue end

            -- Held back to here, since a decode that holds never has a tag to report.
            local tag = joins[watcher[spot]].tag
            Log.reject (Catalog.TAG, {
                pathId = tag.pathId,
                expectId = tag.expectId,
                got = slots[leaf],
            })
        end

        --[[
            A grid running from nothing in whole steps hands back the index it was given, and the
            reading for one is held as nothing at all rather than as a call answering the same,
            so a word of them has none to ask after and none of them is reached for here.
        ]]
        if flatly then
            for index, key in keys do
                into[key] = slots[index]
            end

            return bare
        end

        --[[
            A word of fields that neither dissolve nor gather puts every reading straight onto the
            record it was handed, so none of what the walk below carries for the rest is asked for.
            Split here the way the writing half splits, rather than asked field by field.
        ]]
        if simple then
            for index, key in keys do
                local reading = readings[index]
                local raw = slots[index]
                into[key] = if reading == nil then raw else reading (raw)
            end

            return bare
        end

        local keys, readings, pushes, starts = keys, readings, pushes, starts

        for index = 1, reach do
            local at = starts[index]
            local key = keys[index]

            local one: any
            local push = pushes[index]
            if push ~= nil then
                one = push (slots, at)
            else
                local reading = readings[index]
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
                for index, key in keys do
                    local one = value[key]
                    local made = writes[index] (one)
                    if made == nil then Word.refused (wheres[index], wanted[index], one) end

                    buffer.writeu8 (b, at, made :: number)
                    at += 1
                end
            end

            -- The same, where a whole number already on the grid is the index and asks nothing.
            local function ready (b: buffer, pos: number, value: any, _s: { number }, _h: { any })
                local at = pos
                for index, key in keys do
                    local one = value[key]
                    local made = one

                    if
                        type (one) ~= "number"
                        or bit32.bor (one, 0) ~= one
                        or one > bounds[index]
                    then
                        made = writes[index] (one)
                        if made == nil then Word.refused (wheres[index], wanted[index], one) end
                    end

                    buffer.writeu8 (b, at, made :: number)
                    at += 1
                end
            end

            -- A byte off the end of its grid, said by whichever of the two reads below met it.
            local function over (index: number, raw: number)
                local tag = joins[index].tag
                Log.reject (Catalog.TAG, {
                    pathId = tag.pathId,
                    expectId = tag.expectId,
                    got = raw,
                })
            end

            local function settled (
                b: buffer,
                pos: number,
                into: any,
                _s: { number },
                _h: { any }
            ): any
                local at = pos
                for index, key in keys do
                    local raw = buffer.readu8 (b, at)
                    at += 1

                    if raw > bounds[index] then over (index, raw) end

                    local reading = readings[index]
                    into[key] = if reading == nil then raw else reading (raw)
                end

                return nil
            end

            --[[
                The same where every grid runs from nothing in whole steps. A grid like that hands
                back the byte it was given and its reading is held as nothing at all, so a word of
                them has none to ask after and the bytes go onto the record as they come off.
            ]]
            local function stated (
                b: buffer,
                pos: number,
                into: any,
                _s: { number },
                _h: { any }
            ): any
                local at = pos
                for index, key in keys do
                    local raw = buffer.readu8 (b, at)
                    at += 1

                    if raw > bounds[index] then over (index, raw) end

                    into[key] = raw
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
                for _, key in keys do
                    into[key] = buffer.readu8 (b, at)
                    at += 1
                end

                return nil
            end

            --[[
                The same write where every grid fills its byte, so its top is the byte's own and
                every field shares it. A whole number inside the grid is one the byte carries
                unchanged, and masking a reading to the byte answers all three of not a whole
                number, under the bottom and over the top in the one question.
            ]]
            local top = bounds[1]

            local function filled (b: buffer, pos: number, value: any, _s: { number }, _h: { any })
                local top, writes = top, writes

                --[[
                    Walked over the names rather than over their number, since every field of a
                    word laid out this way has one and the walk hands it over as it goes, where
                    counting would have the array asked for it again at every step.
                ]]
                local at = pos
                for index, key in keys do
                    local one = value[key]
                    local made = one

                    if type (one) ~= "number" or bit32.band (one, top) ~= one then
                        made = writes[index] (one)
                        if made == nil then Word.refused (wheres[index], wanted[index], one) end
                    end

                    buffer.writeu8 (b, at, made :: number)
                    at += 1
                end
            end

            if bluntly then return filled, blunt, nil end
            if plainly then return ready, stated, nil end

            return steady, settled, nil
        end

        if upright then
            --[[
                Every field straight to its own bytes. The one definition making a field with no
                key is an optional standing alone, which is a single field reached through a pull,
                and both of those are settled above, so every field here has one to be put under.
            ]]
            local function square (b: buffer, pos: number, value: any, _s: { number }, _h: { any })
                for index, key in keys do
                    local one = value[key]
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

                    if raw > bounds[index] then
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

            return square, upward, nil
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

        --[[
            The top a piece is recognised under. A grid running from nothing in whole steps carries
            a whole number inside it as its own index, so a reading already there asks the grid
            nothing, and one whose grid does not is left `UNDER_ALL` and always asks.
        ]]
        local levels = table.create (#slot, 0)

        for part = 1, #slot do
            local cell = slot[part]
            local index = whose[cell]

            owner[part] = index
            puts[part] = keys[index] :: string
            makes[part] = toIndex[cell]
            takes[part] = fromIndex[cell]
            tops[part] = spans[cell]
            levels[part] = if leaves[cell].plain == true then spans[cell] else UNDER_ALL
        end

        --[[
            Whether no piece of the word is already an index. Nothing a caller hands one like that
            is recognised and nothing off its bytes stands on its own, so both halves of the pair
            below go straight through the grid and neither asks a question it knows the answer to.
        ]]
        local roundly = true
        for part = 1, #slot do
            if levels[part] == UNDER_ALL and takes[part] ~= nil then continue end

            roundly = false
            break
        end

        --[[
            Whether every piece fills the bits it is read out of. Nothing a window can spell is
            then off the grid it belongs to, so the halves below that hold a reading to its top
            are holding it to a bound the bytes cannot pass.
        ]]
        local wholly = true
        for part = 1, #slot do
            if whole[slot[part]] then continue end

            wholly = false
            break
        end

        local function flat (b: buffer, pos: number, value: any, _s: { number }, _h: { any })
            local first, last, puts, levels, makes = first, last, puts, levels, makes
            local offset, where, width = offset, where, width

            for window = 1, windows do
                local acc = 0

                for part = first[window], last[window] do
                    local one = value[puts[part]]
                    local made = one

                    if
                        type (one) ~= "number"
                        or bit32.bor (one, 0) ~= one
                        or one > levels[part]
                    then
                        made = makes[part] (one)
                        if made == nil then
                            local index = owner[part]
                            Word.refused (wheres[index], wanted[index], one)
                        end
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

        -- A piece off the end of its grid, said by whichever of the two readings below met it.
        local function past (part: number, raw: number)
            local tag = joins[owner[part]].tag
            Log.reject (Catalog.TAG, { pathId = tag.pathId, expectId = tag.expectId, got = raw })
        end

        --[[
            The same, taken back up. A field with no key is an optional standing on its own, which
            is a single field reached through a pull, and both of those are settled above, so every
            piece here has a key to be put under and neither half asks whether it does.
        ]]
        local function level (b: buffer, pos: number, into: any, _s: { number }, _h: { any }): any
            local offset, span, tops, takes, puts = offset, span, tops, takes, puts

            for window = 1, windows do
                local at = pos + where[window]
                local bytes = width[window]
                local acc = if bytes == ONE
                    then buffer.readu8 (b, at)
                    elseif bytes == PAIR then buffer.readu16 (b, at)
                    else buffer.readu32 (b, at)

                for part = first[window], last[window] do
                    local raw = bit32.extract (acc, offset[part], span[part])
                    if raw > tops[part] then past (part, raw) end

                    local reading = takes[part]
                    into[puts[part]] = if reading == nil then raw else reading (raw)
                end
            end

            return nil
        end

        --[[
            The same as the one above where no piece can come off the bytes over the top of the
            grid it belongs to, so what the walk asks after is the reading and never the piece.
        ]]
        local function plane (b: buffer, pos: number, into: any, _s: { number }, _h: { any }): any
            local offset, span, takes, puts = offset, span, takes, puts

            for window = 1, windows do
                local at = pos + where[window]
                local bytes = width[window]
                local acc = if bytes == ONE
                    then buffer.readu8 (b, at)
                    elseif bytes == PAIR then buffer.readu16 (b, at)
                    else buffer.readu32 (b, at)

                for part = first[window], last[window] do
                    local raw = bit32.extract (acc, offset[part], span[part])
                    local reading = takes[part]

                    into[puts[part]] = if reading == nil then raw else reading (raw)
                end
            end

            return nil
        end

        --[[
            The same where every grid runs from nothing in whole steps. A grid like that hands back
            the index it was given and its reading is held as nothing at all, so a word of them has
            none to ask after and the pieces go onto the record as they come off the bytes.
        ]]
        local function bared (b: buffer, pos: number, into: any, _s: { number }, _h: { any }): any
            local first, last, offset, span, tops, puts = first, last, offset, span, tops, puts
            local where, width = where, width

            for window = 1, windows do
                local at = pos + where[window]
                local bytes = width[window]
                local acc = if bytes == ONE
                    then buffer.readu8 (b, at)
                    elseif bytes == PAIR then buffer.readu16 (b, at)
                    else buffer.readu32 (b, at)

                for part = first[window], last[window] do
                    local raw = bit32.extract (acc, offset[part], span[part])
                    if raw > tops[part] then past (part, raw) end

                    into[puts[part]] = raw
                end
            end

            return nil
        end

        --[[
            The pair beside those two for a word wider than one window. Which window a piece sits
            in is the only thing left to work out, none of them being an index already, so the walk
            carries that and asks nothing else.
        ]]
        local function scaled (b: buffer, pos: number, value: any, _s: { number }, _h: { any })
            local first, last, puts, makes, offset = first, last, puts, makes, offset
            local where, width = where, width

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

        local function gauged (b: buffer, pos: number, into: any, _s: { number }, _h: { any }): any
            local first, last, offset, span, tops, takes, puts =
                first, last, offset, span, tops, takes, puts
            local where, width = where, width

            for window = 1, windows do
                local at = pos + where[window]
                local bytes = width[window]
                local acc = if bytes == ONE
                    then buffer.readu8 (b, at)
                    elseif bytes == PAIR then buffer.readu16 (b, at)
                    else buffer.readu32 (b, at)

                for part = first[window], last[window] do
                    local raw = bit32.extract (acc, offset[part], span[part])
                    if raw > tops[part] then past (part, raw) end

                    into[puts[part]] = (takes[part] :: (number) -> any) (raw)
                end
            end

            return nil
        end

        --[[
            The same as the one above where no grid leaves a reading over its top either, so the
            walk puts each piece down as the bytes spell it and asks after none of them.
        ]]
        local function swept (b: buffer, pos: number, into: any, _s: { number }, _h: { any }): any
            local first, last, offset, span, puts = first, last, offset, span, puts
            local where, width = where, width

            for window = 1, windows do
                local at = pos + where[window]
                local bytes = width[window]
                local acc = if bytes == ONE
                    then buffer.readu8 (b, at)
                    elseif bytes == PAIR then buffer.readu16 (b, at)
                    else buffer.readu32 (b, at)

                for part = first[window], last[window] do
                    into[puts[part]] = bit32.extract (acc, offset[part], span[part])
                end
            end

            return nil
        end

        -- The one seat and the one call a word of a single window is read and written at.
        local seat, bytes = where[1], width[1]

        --[[
            The same read where every grid runs from nothing in whole steps as well. Neither the
            window nor the reading is a question then, so the pieces come off the one call and go
            onto the record as they are.
        ]]
        local function simply (b: buffer, pos: number, into: any, _s: { number }, _h: { any }): any
            local acc = if bytes == ONE
                then buffer.readu8 (b, pos + seat)
                elseif bytes == PAIR then buffer.readu16 (b, pos + seat)
                else buffer.readu32 (b, pos + seat)

            local offset, span, tops = offset, span, tops

            for part, key in puts do
                local raw = bit32.extract (acc, offset[part], span[part])
                if raw > tops[part] then past (part, raw) end

                into[key] = raw
            end

            return nil
        end

        --[[
            The same again where no grid leaves a reading over its top, so the one call hands back
            pieces that are each already the value they stand for.
        ]]
        local function sheer (b: buffer, pos: number, into: any, _s: { number }, _h: { any }): any
            local acc = if bytes == ONE
                then buffer.readu8 (b, pos + seat)
                elseif bytes == PAIR then buffer.readu16 (b, pos + seat)
                else buffer.readu32 (b, pos + seat)

            local offset, span = offset, span

            for part, key in puts do
                into[key] = bit32.extract (acc, offset[part], span[part])
            end

            return nil
        end

        --[[
            The same read for that word. One window is one call at one seat, so what the walk
            above carries from window to window is settled before it starts and the pieces are
            the whole of the run rather than a stretch of it.
        ]]
        local function lone (b: buffer, pos: number, into: any, _s: { number }, _h: { any }): any
            local at = pos + seat
            local acc = if bytes == ONE
                then buffer.readu8 (b, at)
                elseif bytes == PAIR then buffer.readu16 (b, at)
                else buffer.readu32 (b, at)

            local offset, span, tops, takes = offset, span, tops, takes

            for part, key in puts do
                local raw = bit32.extract (acc, offset[part], span[part])
                if raw > tops[part] then past (part, raw) end

                local reading = takes[part]
                into[key] = if reading == nil then raw else reading (raw)
            end

            return nil
        end

        -- The same for one window, held to its top by nothing for the same reason.
        local function sound (b: buffer, pos: number, into: any, _s: { number }, _h: { any }): any
            local at = pos + seat
            local acc = if bytes == ONE
                then buffer.readu8 (b, at)
                elseif bytes == PAIR then buffer.readu16 (b, at)
                else buffer.readu32 (b, at)

            local offset, span, takes = offset, span, takes

            for part, key in puts do
                local raw = bit32.extract (acc, offset[part], span[part])
                local reading = takes[part]

                into[key] = if reading == nil then raw else reading (raw)
            end

            return nil
        end

        --[[
            The same write where the word is one window wide, which is every record the bytes of a
            single call can hold. The pieces are then the whole of the run rather than a stretch of
            it, so the walk hands each name over as it goes and the seat is settled once.
        ]]
        if windows == 1 then
            local function alone (b: buffer, pos: number, value: any, _s: { number }, _h: { any })
                local acc = 0

                local offset, levels, makes = offset, levels, makes

                for part, key in puts do
                    local one = value[key]
                    local made = one

                    if
                        type (one) ~= "number"
                        or bit32.bor (one, 0) ~= one
                        or one > levels[part]
                    then
                        made = makes[part] (one)
                        if made == nil then
                            local index = owner[part]
                            Word.refused (wheres[index], wanted[index], one)
                        end
                    end

                    acc = bit32.bor (acc, bit32.lshift (made :: number, offset[part]))
                end

                local at = pos + seat
                if bytes == ONE then
                    buffer.writeu8 (b, at, acc)
                elseif bytes == PAIR then
                    buffer.writeu16 (b, at, acc)
                else
                    buffer.writeu32 (b, at, acc)
                end
            end

            --[[
                The same pair where no grid runs from nothing. Every piece goes down through its own
                grid and comes back up through it, so neither half asks whether the one it holds is
                an index already.
            ]]
            local function round (b: buffer, pos: number, value: any, _s: { number }, _h: { any })
                local acc = 0

                local offset, makes = offset, makes

                for part, key in puts do
                    local one = value[key]
                    local made = makes[part] (one)
                    if made == nil then
                        local index = owner[part]
                        Word.refused (wheres[index], wanted[index], one)
                    end

                    acc = bit32.bor (acc, bit32.lshift (made :: number, offset[part]))
                end

                local at = pos + seat
                if bytes == ONE then
                    buffer.writeu8 (b, at, acc)
                elseif bytes == PAIR then
                    buffer.writeu16 (b, at, acc)
                else
                    buffer.writeu32 (b, at, acc)
                end
            end

            local function graded (
                b: buffer,
                pos: number,
                into: any,
                _s: { number },
                _h: { any }
            ): any
                local at = pos + seat
                local acc = if bytes == ONE
                    then buffer.readu8 (b, at)
                    elseif bytes == PAIR then buffer.readu16 (b, at)
                    else buffer.readu32 (b, at)

                local offset, span, tops, takes = offset, span, tops, takes

                for part, key in puts do
                    local raw = bit32.extract (acc, offset[part], span[part])
                    if raw > tops[part] then past (part, raw) end

                    into[key] = (takes[part] :: (number) -> any) (raw)
                end

                return nil
            end

            if flatly and wholly then return alone, sheer, nil end
            if flatly then return alone, simply, nil end
            if roundly then return round, graded, nil end
            if wholly then return alone, sound, nil end

            return alone, lone, nil
        end

        if flatly and wholly then return flat, swept, nil end
        if flatly then return flat, bared, nil end
        if roundly then return scaled, gauged, nil end
        if wholly then return flat, plane, nil end

        return flat, level, nil
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
        local reading = fromIndex[cell]
        local writing = toIndex[cell]
        local bound = spans[cell]
        local level = if leaves[cell].plain == true then bound else UNDER_ALL
        local said, want = wheres[1], wanted[1]
        local seat, bytes = where[1], width[1]
        local sign = joins[1].tag
        local named, meant = sign.pathId, sign.expectId

        local function only (b: buffer, pos: number, value: any, slots: { number }, _held: { any })
            local one = if key == nil then value else value[key]
            local made = one

            if type (one) ~= "number" or bit32.bor (one, 0) ~= one or one > level then
                made = writing (one)
                if made == nil then Word.refused (said, want, one) end
            end

            local at = pos + seat
            if bytes == ONE then
                buffer.writeu8 (b, at, made :: number)
            elseif bytes == PAIR then
                buffer.writeu16 (b, at, made :: number)
            else
                buffer.writeu32 (b, at, made :: number)
            end
        end

        --[[
            Which buffer read a field takes follows from a width settled when this closure was
            built, so the three are three closures and no payload is asked which of them it wants.
        ]]
        local function narrow (b: buffer, pos: number, into: any, _s: { number }, _h: { any }): any
            local raw = buffer.readu8 (b, pos + seat)
            if raw > bound then
                Log.reject (Catalog.TAG, { pathId = named, expectId = meant, got = raw })
            end

            local one = if reading == nil then raw else reading (raw)
            if key == nil then return one end

            into[key] = one
            return nil
        end

        local function middle (b: buffer, pos: number, into: any, _s: { number }, _h: { any }): any
            local raw = buffer.readu16 (b, pos + seat)
            if raw > bound then
                Log.reject (Catalog.TAG, { pathId = named, expectId = meant, got = raw })
            end

            local one = if reading == nil then raw else reading (raw)
            if key == nil then return one end

            into[key] = one
            return nil
        end

        local function widest (b: buffer, pos: number, into: any, _s: { number }, _h: { any }): any
            local raw = buffer.readu32 (b, pos + seat)
            if raw > bound then
                Log.reject (Catalog.TAG, { pathId = named, expectId = meant, got = raw })
            end

            local one = if reading == nil then raw else reading (raw)
            if key == nil then return one end

            into[key] = one
            return nil
        end

        --[[
            A lone field over a grid whose readings are their own indices has nothing to do to one
            but hand it back, and where the block is that word alone there is no part after it to
            place. So these answer the block's own two, the byte past the word and the reading, and
            they sit at the word's first byte, which is one more thing the build settles for them.
        ]]
        local after = of.maxBytes

        local function soloByte (b: buffer, pos: number, _c: any): (number, any)
            local raw = buffer.readu8 (b, pos)
            if raw > bound then
                Log.reject (Catalog.TAG, { pathId = named, expectId = meant, got = raw })
            end

            return pos + after, raw
        end

        local function soloPair (b: buffer, pos: number, _c: any): (number, any)
            local raw = buffer.readu16 (b, pos)
            if raw > bound then
                Log.reject (Catalog.TAG, { pathId = named, expectId = meant, got = raw })
            end

            return pos + after, raw
        end

        local function soloWide (b: buffer, pos: number, _c: any): (number, any)
            local raw = buffer.readu32 (b, pos)
            if raw > bound then
                Log.reject (Catalog.TAG, { pathId = named, expectId = meant, got = raw })
            end

            return pos + after, raw
        end

        local sole = if bytes == ONE then narrow elseif bytes == PAIR then middle else widest
        local solo = if key ~= nil
                or reading ~= nil
                or seat ~= 0
            then nil
            else (if bytes == ONE then soloByte elseif bytes == PAIR then soloPair else soloWide)

        return only, sole, solo
    end

    return pack, unpack, nil
end

return table.freeze (Word)
