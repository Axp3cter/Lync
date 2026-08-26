--!strict
--!native
--!optimize 2
-- The nodes made of other nodes, as the pair of closures that puts each one's children in order.

local Bits = require ("@src/kernel/Bits")
local Bytes = require ("@src/wire/Bytes")
local Catalog = require ("@src/kernel/Catalog")
local Ir = require ("@src/shape/Ir")
local Log = require ("@src/kernel/Log")
local Serial = require ("@src/shape/Serial")
local Types = require ("@src/Types")
local Word = require ("@src/shape/emit/Word")

local Block = {}

-- Constants -----------------------------------------------------------

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

    return write, read
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

    local function write (b: buffer, pos: number, value: any): number
        if typeof (value) ~= engine then Word.refusedAt (tag, paths, expected, value) end

        local at = pos
        for index = 1, reach do
            at = writes[index] (b, at, value[keys[index]])
        end
        return at
    end

    local function read (b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
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

    local function before (a: number, b: number): boolean
        return Bytes.rangeLess (room, starts[a], widths[a], starts[b], widths[b])
    end

    local function write (b: buffer, pos: number, value: any): number
        table.clear (order)

        local count = 0
        local at = 0

        for key in value do
            count += 1
            if count > high then Word.refusedAt (tag, paths, said, count) end

            keys[count] = key
            starts[count] = at
            at = writeKey (room, at, key)

            widths[count] = at - starts[count]
            order[count] = count
        end

        if count < low then Word.refusedAt (tag, paths, said, count) end
        table.sort (order, before)

        laid (b, pos, held, count - low)

        local out = pos + held
        for index = 1, count do
            local place = order[index]
            if index > 1 and not before (order[index - 1], place) then
                local last = keys[order[index - 1]]
                Log.refuse (Log.line (Catalog.MAP_ORDER, {
                    path = where,
                    expected = tostring (last),
                    got = tostring (keys[place]),
                }))
            end

            buffer.copy (b, out, room, starts[place], widths[place])
            out = writeValue (b, out + widths[place], value[keys[place]])
        end
        return out
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

            at, out[key] = readValue (b, at, ctx)
        end
        return at, out
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
