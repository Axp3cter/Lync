--!strict
--!native
--!optimize 2
-- The nodes made of other nodes, as the pair of closures that puts each one's children in order.

local Bits = require ("@src/kernel/Bits")
local Bytes = require ("@src/wire/Bytes")
local Catalog = require ("@src/kernel/Catalog")
local Grid = require ("@src/shape/Grid")
local Ir = require ("@src/shape/Ir")
local Leaf = require ("@src/shape/emit/Leaf")
local Log = require ("@src/kernel/Log")
local Serial = require ("@src/shape/Serial")
local Types = require ("@src/Types")
local Word = require ("@src/shape/emit/Word")

local Block = {}

-- Constants -----------------------------------------------------------

--[[
    The two run walkers under their own names. Both sit inside closures these emit, so each is
    reached once a run rather than once a build, and the module they come from is the same table
    for the life of the place.
]]
const PACKED = Leaf.packed
const UNPACKED = Leaf.unpacked

-- The whole-byte widths a tag or a count is written at, and where a three-byte one splits.
const PAIR = 2
const TRIO = PAIR + 1
const HALF = 2 ^ 16

-- Private -------------------------------------------------------------

--[[
    A tag or a count, as the whole bytes it occupies. Narrower than the leaf writer's, because
    nothing composed here is wider than a count, and a bound past four bytes is more elements than a
    caller could hold the values for.
]]
local function laid (b: buffer, at: number, bytes: number, value: number)
    if bytes == 0 then return end
    if bytes == 1 then return buffer.writeu8 (b, at, value) end
    if bytes == PAIR then return buffer.writeu16 (b, at, value) end
    if bytes == TRIO then
        buffer.writeu16 (b, at, value % HALF)
        return buffer.writeu8 (b, at + PAIR, value // HALF)
    end
    buffer.writeu32 (b, at, value)
end

local function taken (b: buffer, at: number, bytes: number): number
    if bytes == 0 then return 0 end
    if bytes == 1 then return buffer.readu8 (b, at) end
    if bytes == PAIR then return buffer.readu16 (b, at) end
    if bytes == TRIO then return buffer.readu16 (b, at) + buffer.readu8 (b, at + PAIR) * HALF end
    return buffer.readu32 (b, at)
end

-- Public --------------------------------------------------------------

--[[
    A region and then everything after it, which is what a record is. The two arrays a call meets
    its own state in are made once here and neither survives a call, and a group cannot appear
    inside itself, so two calls through the pair never overlap. A dissolved record is resolved once
    before either region and filled from both, which keeps two tables of one name from being built.
]]
function Block.group (
    of: Ir.Group,
    pack: Word.Pack?,
    unpack: Word.Unpack?,
    solo: Word.Solo?,
    writes: { Ir.Write },
    reads: { Ir.Read },
    paths: Serial.Interner,
    said: Serial.Interner
): (Ir.Write, Ir.Read)
    local slots: { number } = {}
    local held: { any } = {}
    local region = if of.word == nil then 0 else of.word.maxBytes

    local deep = #of.nests
    local names = table.create (deep) :: { string }
    local unders = table.create (deep, 0)
    local nested = table.create (deep) :: { Ir.Tag }
    local slack = table.create (deep) :: { { [string]: boolean } }

    for index, nest in of.nests do
        names[index] = nest.key
        unders[index] = nest.under or 0
        nested[index] = nest.tag
        slack[index] = nest.allow
    end

    local reach = #of.parts
    local keys = table.create (reach) :: { string? }
    local inside = table.create (reach, 0)
    local bits = table.create (reach, 0)

    local keyed = true

    for index, part in of.parts do
        local shape = part.of
        keys[index] = part.key
        inside[index] = part.nest or 0
        bits[index] = if shape.op == "opt" then shape.bit else 0
        if part.key == nil then keyed = false end
    end

    if of.word ~= nil then
        for _, join in of.word.joins do
            if join.key == nil then keyed = false end
        end
    end

    --[[
        The record's own names, as a table to copy rather than one to grow, since a record started
        empty rehashes as each name lands on it. A name the frame left out is taken back off once
        below, which is an assignment where growing the record is a rehash of everything on it.
    ]]
    local blank: any = nil

    if keyed then
        local shape: { [string]: boolean } = {}

        for index = 1, deep do
            if unders[index] == 0 then shape[names[index]] = false end
        end

        if of.word ~= nil then
            for _, join in of.word.joins do
                local key = join.key
                if key ~= nil and (join.nest or 0) == 0 then shape[key] = false end
            end
        end

        for index = 1, reach do
            local key = keys[index]
            if key ~= nil and inside[index] == 0 then shape[key] = false end
        end

        blank = shape
    end

    -- A record carries the names it declares and no others, at every depth it dissolved through.
    local function only (of: { [string]: boolean }, tag: Ir.Tag, record: any)
        if type (record) ~= "table" then Word.refusedAt (tag, paths, said, record) end

        for key in record do
            if of[key] ~= nil then continue end
            Word.refusedAt (tag, paths, said, key)
        end
    end

    local allow = of.allow

    local function write (b: buffer, pos: number, value: any): number
        if allow ~= nil then only (allow, of.tag, value) end

        for index = 1, deep do
            local under = unders[index]
            local one = (if under == 0 then value else held[under])[names[index]]
            only (slack[index], nested[index], one)

            held[index] = one
        end

        if pack ~= nil then pack (b, pos, value, slots, held) end

        local at = pos + region
        for index = 1, reach do
            local key = keys[index]
            local within = inside[index]
            local from = if within == 0 then value else held[within]
            local one = if key == nil then from else from[key]

            local bit = bits[index]
            if bit ~= 0 and slots[bit] == 0 then continue end

            at = writes[index] (b, at, one)
        end
        return at
    end

    local function read (b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
        local into: any = if blank ~= nil then table.clone (blank) elseif keyed then {} else nil
        local bare: any = nil

        for index = 1, deep do
            local under = unders[index]
            local up = if under == 0 then into else held[under]

            local one = {}
            up[names[index]] = one
            held[index] = one
        end

        if unpack ~= nil then bare = unpack (b, pos, into, slots, held) end

        local at = pos + region
        for index = 1, reach do
            local bit = bits[index]
            local key = keys[index]

            if bit ~= 0 and slots[bit] == 0 then
                if key ~= nil and blank ~= nil then
                    local absent = inside[index]
                    local off = if absent == 0 then into else held[absent]
                    off[key] = nil
                end

                continue
            end

            local one: any
            at, one = reads[index] (b, at, ctx)

            if key == nil then
                bare = one
                continue
            end

            local within = inside[index]
            local up = if within == 0 then into else held[within]
            up[key] = one
        end

        return at, (if keyed then into else bare)
    end

    --[[
        Whether every part of this group lands on the record itself and is always there. Dissolving
        nothing settles where a part goes, since a part is only put inside a record that dissolved,
        and holding the keys settles that there is a shape to copy. What is left to ask is whether
        any part is an option, which is a bit deciding at read time whether it came at all.
    ]]
    local plainly = deep == 0 and keyed
    if plainly then
        for index = 1, reach do
            if bits[index] == 0 then continue end

            plainly = false
            break
        end
    end

    --[[
        A group that dissolved nothing, names nothing and keeps nothing outside its word, which is
        a packet declared as one value rather than as a record. Neither half has a part to walk or
        a name to put one under, so each is the word alone with the region stepped over.
    ]]
    if
        deep == 0
        and reach == 0
        and not keyed
        and allow == nil
        and pack ~= nil
        and unpack ~= nil
    then
        local packing, unpacking = pack, unpack

        local function worded (b: buffer, pos: number, value: any): number
            packing (b, pos, value, slots, held)
            return pos + region
        end

        local function spelled (b: buffer, pos: number, _c: Types.ValidateContext): (number, any)
            return pos + region, unpacking (b, pos, nil, slots, held)
        end

        -- The word's own pair where it offers one, which is this block's without the hop between.
        if solo == nil then return worded, spelled end

        return solo.write, solo.read or spelled
    end

    if not plainly then return write, read end

    --[[
        The same write. Nothing dissolved, so no part is reached through a record held aside, and
        no part is an option, so none of them is a bit away from not being written at all.
    ]]
    local function laid (b: buffer, pos: number, value: any): number
        if allow ~= nil then only (allow, of.tag, value) end
        if pack ~= nil then pack (b, pos, value, slots, held) end

        local at = pos + region
        for index = 1, reach do
            at = writes[index] (b, at, value[keys[index]])
        end

        return at
    end

    -- The same read where each part goes straight onto the record, which is where most of them do.
    local function plain (b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
        local into: any = table.clone (blank)

        -- Holding the keys means every part has one, so nothing here is read without a key.
        if unpack ~= nil then unpack (b, pos, into, slots, held) end

        local at = pos + region
        for index = 1, reach do
            local one: any
            at, one = reads[index] (b, at, ctx)

            into[keys[index]] = one
        end

        return at, into
    end

    if allow == nil or pack == nil or unpack == nil then return laid, plain end

    --[[
        The same pair for a group that declares its names and holds a word, which is most of them.
        Whether it does is settled when the group is built, so the pair above asks it once a record
        where the answer was the same every time.
    ]]
    local function stated (b: buffer, pos: number, value: any): number
        only (allow, of.tag, value)
        pack (b, pos, value, slots, held)

        local at = pos + region
        for index = 1, reach do
            at = writes[index] (b, at, value[keys[index]])
        end

        return at
    end

    local function sorted (b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
        local into: any = table.clone (blank)
        unpack (b, pos, into, slots, held)

        local at = pos + region
        for index = 1, reach do
            local one: any
            at, one = reads[index] (b, at, ctx)

            into[keys[index]] = one
        end

        return at, into
    end

    --[[
        The same pair for a group holding one part outside its word, which is a record carrying a
        string, an array or a map beside the names its bytes fit. One part is no run to climb, so
        what climbs it is a loop set up to go round once.
    ]]
    if reach == 1 then
        local key = keys[1]
        local put, take = writes[1], reads[1]

        local function singly (b: buffer, pos: number, value: any): number
            only (allow, of.tag, value)
            pack (b, pos, value, slots, held)

            return put (b, pos + region, value[key])
        end

        local function singled (b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
            local into: any = table.clone (blank)
            unpack (b, pos, into, slots, held)

            local at, one = take (b, pos + region, ctx)
            into[key] = one

            return at, into
        end

        return singly, singled
    end

    --[[
        The same pair for a group with nothing outside its word, which is every record whose names
        all fit the bytes the word plans. There is no part left to walk, so what walks them is a
        climb over none, taken once a record for as long as the schema runs.
    ]]
    if reach == 0 then
        local function worded (b: buffer, pos: number, value: any): number
            only (allow, of.tag, value)
            pack (b, pos, value, slots, held)

            return pos + region
        end

        local function spelt (b: buffer, pos: number, _c: Types.ValidateContext): (number, any)
            local into: any = table.clone (blank)
            unpack (b, pos, into, slots, held)

            return pos + region, into
        end

        return worded, spelt
    end

    return stated, sorted
end

-- A value laid down as its parts and built back out of them.
function Block.apart (
    of: Ir.Apart,
    writes: { Ir.Write },
    reads: { Ir.Read },
    paths: Serial.Interner,
    expected: Serial.Interner
): (Ir.Write, Ir.Read)
    local tag = of.tag
    local engine = of.engine
    local keys = of.keys
    local push = of.push
    local reach = #of.parts

    local held = table.create (reach) :: { any }

    --[[
        Two parts and three, which between them are every value this emitter is given. How many
        there are is settled when the word is built, so a walk over them is a walk to a number
        already known, and each part's writer and name are settled with it rather than looked up
        at every value that goes past.
    ]]
    if reach == PAIR then
        local first, second = writes[1], writes[2]
        local one, two = keys[1], keys[2]

        local function write (b: buffer, pos: number, value: any): number
            if typeof (value) ~= engine then Word.refusedAt (tag, paths, expected, value) end

            return second (b, first (b, pos, value[one]), value[two])
        end

        local function read (b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
            local at, held = pos, held

            at, held[1] = reads[1] (b, at, ctx)
            at, held[2] = reads[2] (b, at, ctx)

            return at, push (held)
        end

        return write, read
    end

    if reach == TRIO then
        local first, second, third = writes[1], writes[2], writes[TRIO]
        local one, two, three = keys[1], keys[2], keys[TRIO]

        local function write (b: buffer, pos: number, value: any): number
            if typeof (value) ~= engine then Word.refusedAt (tag, paths, expected, value) end

            local at = first (b, pos, value[one])
            at = second (b, at, value[two])
            return third (b, at, value[three])
        end

        local function read (b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
            local at, held = pos, held

            at, held[1] = reads[1] (b, at, ctx)
            at, held[2] = reads[2] (b, at, ctx)
            at, held[TRIO] = reads[TRIO] (b, at, ctx)

            return at, push (held)
        end

        return write, read
    end

    local function write (b: buffer, pos: number, value: any): number
        if typeof (value) ~= engine then Word.refusedAt (tag, paths, expected, value) end

        -- The part writers and the names they take, reached once rather than once a part.
        local writes, keys = writes, keys

        local at = pos
        for index = 1, reach do
            at = writes[index] (b, at, value[keys[index]])
        end
        return at
    end

    local function read (b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
        -- The same the other way, the readers and the array their answers go into.
        local reads, held = reads, held

        local at = pos
        for index = 1, reach do
            at, held[index] = reads[index] (b, at, ctx)
        end
        return at, push (held)
    end

    return write, read
end

--[[
    A tag and the arm it chooses, and nothing to choose it by but the field the variant names itself
    in.
]]
function Block.branch (
    of: Ir.Branch,
    writes: { Ir.Write },
    reads: { Ir.Read },
    paths: Serial.Interner,
    said: Serial.Interner
): (Ir.Write, Ir.Read)
    local tag = of.tag
    local field = of.field
    local bytes = Bytes.whole (of.tagWidth)
    local reach = #of.arms

    local index: { [string]: number } = {}
    local names = table.create (reach) :: { string }

    for place, name in of.names do
        index[name] = place
        names[place] = name
    end

    local function write (b: buffer, pos: number, value: any): number
        local place = index[value[field]]
        if place == nil then Word.refusedAt (tag, paths, said, value[field]) end

        laid (b, pos, bytes, (place :: number) - 1)
        return writes[place :: number] (b, pos + bytes, value)
    end

    local function read (b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
        local place = taken (b, pos, bytes) + 1
        if place > reach then
            Log.reject (Catalog.TAG, {
                pathId = tag.pathId,
                expectId = tag.expectId,
                got = place - 1,
            })
        end

        local at, one = reads[place] (b, pos + bytes, ctx)
        one[field] = names[place]
        return at, one
    end

    return write, read
end

--[[
    A count and then that many of one thing, each starting on a byte because the thing before it
    ended on one.
]]
function Block.list (
    of: Ir.List,
    writeElem: Ir.Write,
    readElem: Ir.Read,
    paths: Serial.Interner,
    said: Serial.Interner
): (Ir.Write, Ir.Read)
    local tag = of.tag
    local low, high = of.count.min, of.count.max
    local span = high - low
    local held = Bytes.whole (Bits.width (span))

    local function write (b: buffer, pos: number, value: any): number
        local count = #value
        if count < low or count > high then Word.refusedAt (tag, paths, said, count) end

        laid (b, pos, held, count - low)

        local at = pos + held
        for index = 1, count do
            at = writeElem (b, at, value[index])
        end
        return at
    end

    local function read (b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
        local counted = taken (b, pos, held)
        if counted > span then
            Log.reject (
                Catalog.COUNT,
                { pathId = tag.pathId, expectId = tag.expectId, got = counted }
            )
        end

        local count = counted + low
        local out = table.create (count) :: { any }
        local at = pos + held

        for index = 1, count do
            at, out[index] = readElem (b, at, ctx)
        end
        return at, out
    end

    return write, read
end

-- A count and then that many pairs, in the order the bytes of their keys read in.
function Block.pairs (
    of: Ir.Pairs,
    writeKey: Ir.Write,
    readKey: Ir.Read,
    writeValue: Ir.Write,
    readValue: Ir.Read,
    paths: Serial.Interner,
    said: Serial.Interner
): (Ir.Write, Ir.Read)
    local tag = of.tag
    local low, high = of.count.min, of.count.max
    local span = high - low
    local held = Bytes.whole (Bits.width (span))

    local where = paths.texts[tag.pathId]

    local room = buffer.create (high * of.key.maxBytes)
    local keys: { any } = {}
    local starts: { number } = {}
    local widths: { number } = {}
    local order: { number } = {}

    --[[
        What each key's leading bytes come to, so the sort settles most pairs on two numbers. A pair
        that ties there is still asked the whole question, which is what keeps the order the bytes'
        own rather than the number's.
    ]]
    local ranks: { number } = {}

    local function before (a: number, b: number): boolean
        local rankA, rankB = ranks[a], ranks[b]
        if rankA ~= rankB then return rankA < rankB end

        --[[
            The bytes a tie has already answered for, stepped over. A leading number holds the
            width itself, so two that tie belong to keys of one width whose leading bytes are the
            same ones, and what is left to ask about is everything past them.
        ]]
        local past = Bytes.LEADING
        return Bytes.rangeLess (
            room,
            starts[a] + past,
            widths[a] - past,
            starts[b] + past,
            widths[b] - past
        )
    end

    --[[
        The same without the leading bytes, for a map whose keys all begin alike. Every rank ties
        there, so asking them is a question with one answer, and the sort is handed the comparison
        that was going to be reached for anyway.
    ]]
    local function bytewise (a: number, b: number): boolean
        return Bytes.rangeLess (room, starts[a], widths[a], starts[b], widths[b])
    end

    --[[
        Keys of one narrow width order by a number rather than by their bytes, and a sort told to
        order numbers calls nothing to ask. A comparison that reaches a function of ours is one the
        sort pays for on every pair it looks at, which is most of what a map spends.
    ]]
    local marks: { number } = {}
    local owners: { any } = {}

    -- How the values lie, which the shape decided when it said what it weighs.
    local runs: Grid.Grid? = of.runs

    local even = of.key.fixed and Bytes.ranks (of.key.maxBytes)
    local wide = of.key.maxBytes

    -- The index rides under the rank, so one sort answers both what the order is and whose it is.
    local spread = high + 1

    --[[
        Keys that are one reading on a grid sort as the numbers they are and lie end to end in the
        bits they take. Nothing is spelled into scratch to be compared and copied back out, since
        what orders two keys is what the grid already turned them into.
    ]]
    local sorts: Grid.Grid? = of.keyed

    local function running (b: buffer, pos: number, value: any): number
        local grid = sorts :: Grid.Grid

        table.clear (order)
        local count = 0

        local toIndex = grid.toIndex

        for key in value do
            count += 1
            if count > high then Word.refusedAt (tag, paths, said, count) end

            local made = toIndex (key)
            if made == nil then Word.refusedAt (tag, paths, said, key) end

            order[count] = made :: number
            owners[made :: number] = key
        end

        if count < low then Word.refusedAt (tag, paths, said, count) end
        table.sort (order)

        for index = 2, count do
            if order[index] ~= order[index - 1] then continue end
            Log.refuse (Log.line (Catalog.MAP_ORDER, {
                path = where,
                expected = tostring (owners[order[index]]),
                got = tostring (owners[order[index]]),
            }))
        end

        laid (b, pos, held, count - low)
        local out = PACKED (b, pos + held, grid.width, count, order)

        if runs == nil then
            for index = 1, count do
                out = writeValue (b, out, value[owners[order[index]]])
            end

            return out
        end

        local held2 = runs :: Grid.Grid
        for index = 1, count do
            local one = value[owners[order[index]]]
            local made = held2.toIndex (one)
            if made == nil then Word.refusedAt (tag, paths, said, one) end

            marks[index] = made :: number
        end

        return PACKED (b, out, held2.width, count, marks)
    end

    local function write (b: buffer, pos: number, value: any): number
        if sorts ~= nil then return running (b, pos, value) end

        table.clear (order)

        local count = 0
        local at = 0

        --[[
            The narrowest and widest rank seen, which tells a map whose keys all begin alike from
            one whose do not, without a second walk over them.
        ]]
        local least, most = 0, 0

        for key in value do
            count += 1
            if count > high then Word.refusedAt (tag, paths, said, count) end

            keys[count] = key

            local from = at
            at = writeKey (room, at, key)

            --[[
                Where a key sits and how wide it is, for keys that do not all spell the same width.
                The ones that do are found by counting instead, and the order they sort in is put
                down below rather than here, so nothing is written that is written over.
            ]]
            if not even then
                local wide = at - from
                starts[count] = from
                widths[count] = wide
                order[count] = count
                local rank = Bytes.leading (room, from, wide)
                ranks[count] = rank

                if count == 1 then
                    least, most = rank, rank
                elseif rank < least then
                    least = rank
                elseif rank > most then
                    most = rank
                end
            end
        end

        if count < low then Word.refusedAt (tag, paths, said, count) end

        if even then
            for index = 1, count do
                order[index] = Bytes.ranked (room, (index - 1) * wide, wide) * spread + index
            end
        end

        if even then
            table.sort (order)
        elseif least == most then
            table.sort (order, bytewise)
        else
            table.sort (order, before)
        end

        laid (b, pos, held, count - low)

        local out = pos + held
        local ranked = 0
        for index = 1, count do
            local held = order[index]
            local place = if even then held % spread else held

            if even then
                local rank = (held - place) / spread
                if index > 1 and rank == ranked then
                    Log.refuse (Log.line (Catalog.MAP_ORDER, {
                        path = where,
                        expected = tostring (keys[place]),
                        got = tostring (keys[place]),
                    }))
                end

                ranked = rank
            elseif index > 1 and not before (order[index - 1], place) then
                local last = keys[order[index - 1]]
                Log.refuse (Log.line (Catalog.MAP_ORDER, {
                    path = where,
                    expected = tostring (last),
                    got = tostring (keys[place]),
                }))
            end

            local from = if even then (place - 1) * wide else starts[place]
            local cut = if even then wide else widths[place]

            buffer.copy (b, out, room, from, cut)
            out += cut

            local one = value[keys[place]]
            if runs == nil then
                out = writeValue (b, out, one)
                continue
            end

            local made = (runs :: Grid.Grid).toIndex (one)
            if made == nil then Word.refusedAt (tag, paths, said, one) end

            marks[index] = made :: number
        end

        if runs == nil then return out end

        return PACKED (b, out, (runs :: Grid.Grid).width, count, marks)
    end

    local function taking (b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
        local grid = sorts :: Grid.Grid
        local counted = taken (b, pos, held)
        if counted > span then
            Log.reject (
                Catalog.COUNT,
                { pathId = tag.pathId, expectId = tag.expectId, got = counted }
            )
        end

        local count = counted + low
        local after, clean = UNPACKED (b, pos + held, grid.width, count, order)
        if not clean then Log.reject (Catalog.PAD, { pathId = tag.pathId, got = count }) end

        --[[
            Climbing rather than merely sorted, which answers two things at once: a pair out of
            order and a key the map already holds are both a reading no higher than the last.
        ]]
        local span, fromIndex = grid.span, grid.fromIndex

        --[[
            The first reading held to the grid on its own, since what the rest are held to besides
            is the one before them and the first has none. Asked inside the walk the question would
            be put to every reading for the sake of the one it is about.
        ]]
        local first = order[1]
        if count > 0 and first > span then
            Log.reject (Catalog.TAG, { pathId = tag.pathId, got = first })
        end

        for index = 2, count do
            local mark = order[index]
            if mark > span then Log.reject (Catalog.TAG, { pathId = tag.pathId, got = mark }) end

            local under = order[index - 1]
            if mark <= under then
                Log.reject (Catalog.MAP_ORDER, {
                    pathId = tag.pathId,
                    expected = tostring (fromIndex (under)),
                    got = tostring (fromIndex (mark)),
                })
            end
        end

        local out: any = {}
        if runs == nil then
            local at = after
            for index = 1, count do
                at, out[fromIndex (order[index])] = readValue (b, at, ctx)
            end

            return at, out
        end

        local spare = runs :: Grid.Grid
        local ends, tidy = UNPACKED (b, after, spare.width, count, marks)
        if not tidy then Log.reject (Catalog.PAD, { pathId = tag.pathId, got = count }) end

        for index = 1, count do
            local mark = marks[index]
            if mark > spare.span then
                Log.reject (Catalog.TAG, { pathId = tag.pathId, got = mark })
            end

            out[grid.fromIndex (order[index])] = spare.fromIndex (mark)
        end

        return ends, out
    end

    local function read (b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
        if sorts ~= nil then return taking (b, pos, ctx) end

        local counted = taken (b, pos, held)
        if counted > span then
            Log.reject (
                Catalog.COUNT,
                { pathId = tag.pathId, expectId = tag.expectId, got = counted }
            )
        end

        local count = counted + low
        local out: any = {}
        local at = pos + held

        local was, wide, last = 0, 0, nil :: any
        for index = 1, count do
            local from = at

            local key: any
            at, key = readKey (b, at, ctx)

            if index > 1 and not Bytes.rangeLess (b, was, wide, from, at - from) then
                Log.reject (Catalog.MAP_ORDER, {
                    pathId = tag.pathId,
                    expected = tostring (last),
                    got = tostring (key),
                })
            end
            -- A key this map already holds, which is a pair that would take the place of another.
            if out[key] ~= nil then
                Log.reject (Catalog.MAP_ORDER, {
                    pathId = tag.pathId,
                    expected = tostring (last),
                    got = tostring (key),
                })
            end

            was, wide, last = from, at - from, key

            if runs == nil then
                at, out[key] = readValue (b, at, ctx)
            else
                --[[
                    Put down under its key before the values are read, so the check above reads a
                    map holding every key that came before this one either way. The values arrive
                    as one run after the keys, and each of them lands on its own key below.
                ]]
                owners[index] = key
                out[key] = key
            end
        end

        if runs == nil then return at, out end

        --[[
            Every value of the map, read off the run its keys were followed by. A reading past the
            grid is one no writer of this schema produced, so it is turned away rather than folded
            back onto the last point the grid has.
        ]]
        local grid = runs :: Grid.Grid
        local after, clean = UNPACKED (b, at, grid.width, count, marks)
        if not clean then Log.reject (Catalog.PAD, { pathId = tag.pathId, got = count }) end

        for index = 1, count do
            local mark = marks[index]
            if mark > grid.span then
                Log.reject (Catalog.TAG, { pathId = tag.pathId, got = mark })
            end

            out[owners[index]] = grid.fromIndex (mark)
        end

        return after, out
    end

    return write, read
end

-- A value on its way to and from the one the wire carries, which is the same bytes either way.
function Block.xform (of: Ir.Xform, writeInner: Ir.Write, readInner: Ir.Read): (Ir.Write, Ir.Read)
    local lift, lower = of.lift, of.lower

    local function write (b: buffer, pos: number, value: any): number
        return writeInner (b, pos, lower (value))
    end

    local function read (b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
        local at, one = readInner (b, pos, ctx)
        return at, lift (one)
    end

    return write, read
end

return table.freeze (Block)
