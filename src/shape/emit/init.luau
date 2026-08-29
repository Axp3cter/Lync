--!strict
--!native
--!optimize 2
-- A shape and everything under it, as the one pair of closures the whole tree became.

local Base = require ("@src/codec/Base")
local Block = require ("@src/shape/emit/Block")
local Catalog = require ("@src/kernel/Catalog")
local Ir = require ("@src/shape/Ir")
local Leaf = require ("@src/shape/emit/Leaf")
local Log = require ("@src/kernel/Log")
local Serial = require ("@src/shape/Serial")
local Types = require ("@src/Types")
local Word = require ("@src/shape/emit/Word")

local Emit = {}

-- Types ---------------------------------------------------------------

-- Everything a walk needs besides the node, which here includes the sidecar a slot writes into.
export type Site = {
    read paths: Serial.Interner,
    read expected: Serial.Interner,
    read sidecar: Ir.Sidecar,
}

-- State ---------------------------------------------------------------

-- The first reason a check gave while one payload was decoding, held until that payload is done.
local parkedPath: number? = nil
local parkedReason: string? = nil

--[[
    How many checks this process has wrapped a read in. Counted rather than asked of the tree,
    because the wrapping is where the answer is already known and a walk to rediscover it would be
    the same walk again.
]]
local wrapped = 0

-- Private -------------------------------------------------------------

-- Every check a place declared, in the order they were declared, and the first reason one gives.
local function turned (tag: Ir.Tag, value: any, ctx: Types.ValidateContext)
    local checks = tag.checks :: { Base.Validate }

    for index = 1, #checks do
        local why = checks[index] (value, ctx)
        if why == nil then continue end

        if parkedPath == nil then
            parkedPath = tag.pathId
            parkedReason = why
        end
        return
    end
end

-- A node's own checks, wrapped round the read once here so a node without any pays for nothing.
local function checked (read: Ir.Read, tag: Ir.Tag): Ir.Read
    wrapped += 1

    return function (b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
        local at, value = read (b, pos, ctx)
        turned (tag, value, ctx)
        return at, value
    end
end

-- Where a region's field sits in the record the group answers, as the names to walk to reach it.
local function chained (of: Ir.Group, join: Ir.Join): { string }
    local key = join.key
    local out: { string } = if key == nil then {} else { key }

    local at = join.nest
    while at ~= nil do
        local nest = of.nests[at]
        table.insert (out, 1, nest.key)
        at = nest.under
    end
    return out
end

-- The checks of a region's fields, wrapped round the group that holds the region.
local function fielded (read: Ir.Read, of: Ir.Group): Ir.Read
    local word = of.word
    if word == nil then return read end

    local looks: { Ir.Join } = {}
    local within: { { string } } = {}

    for _, join in word.joins do
        if join.tag.checks == nil then continue end

        table.insert (looks, join)
        table.insert (within, chained (of, join))
    end

    local reach = #looks
    if reach == 0 then return read end

    wrapped += 1

    return function (b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
        local at, value = read (b, pos, ctx)

        for index = 1, reach do
            local one = value
            for _, name in within[index] do
                one = one[name]
            end

            turned (looks[index].tag, one, ctx)
        end

        return at, value
    end
end

-- One node to its pair, with its children already theirs.
local function made (of: Ir.Shape, at: Site): (Ir.Write, Ir.Read)
    local paths, expected = at.paths, at.expected

    --[[
        A region alone is a record with no fields after it. It has joins and so it has a value, but
        the pair that lays a region down fills an array rather than answering, and the thing that
        turns that into a value is the group. So a bare one is emitted as the group it means.
    ]]
    if of.op == "word" then return made (Ir.group (of.tag, of, {}), at) end

    if of.op == "none" then return Leaf.none () end
    if of.op == "wide" then return Leaf.wide (of, paths, expected) end
    if of.op == "f32" or of.op == "f64" then return Leaf.float (of, paths, expected) end
    if of.op == "vlq" or of.op == "vli" then return Leaf.varint (of, paths, expected) end
    if of.op == "bytes" then return Leaf.bytes (of, paths, expected) end
    if of.op == "unknown" then return Leaf.unknown (of, paths, expected) end
    if of.op == "run" then return Leaf.run (of, paths, expected) end

    if of.op == "group" then
        local word = of.word
        local pack: Word.Pack?, unpack: Word.Unpack?, solo: Word.Solo?
        if word ~= nil then
            pack, unpack, solo = Word.emit (word, paths, expected)
        end

        local reach = #of.parts
        local writes = table.create (reach) :: { Ir.Write }
        local reads = table.create (reach) :: { Ir.Read }

        for index, part in of.parts do
            writes[index], reads[index] = Emit.emit (part.of, at)
        end

        local write, read = Block.group (of, pack, unpack, solo, writes, reads, paths, expected)
        return write, fielded (read, of)
    end

    if of.op == "apart" then
        local reach = #of.parts
        local writes = table.create (reach) :: { Ir.Write }
        local reads = table.create (reach) :: { Ir.Read }

        for index, part in of.parts do
            writes[index], reads[index] = Emit.emit (part, at)
        end

        return Block.apart (of, writes, reads, paths, expected)
    end

    if of.op == "list" then
        local write, read = Emit.emit (of.elem, at)
        return Block.list (of, write, read, paths, expected)
    end

    if of.op == "pairs" then
        local writeKey, readKey = Emit.emit (of.key, at)
        local writeValue, readValue = Emit.emit (of.value, at)

        return Block.pairs (of, writeKey, readKey, writeValue, readValue, paths, expected)
    end

    --[[
        An optional is its own value and a bit of the region beside it, and the bit is the group's.
        So there is no closure here that a present field does not already have, and an absent one is
        a call the group does not make.
    ]]
    if of.op == "opt" then return Emit.emit (of.inner, at) end

    if of.op == "branch" then
        local reach = #of.arms
        local writes = table.create (reach) :: { Ir.Write }
        local reads = table.create (reach) :: { Ir.Read }

        for index, arm in of.arms do
            writes[index], reads[index] = Emit.emit (arm, at)
        end

        return Block.branch (of, writes, reads, paths, expected)
    end

    if of.op == "xform" then
        local write, read = Emit.emit (of.inner, at)
        return Block.xform (of, write, read)
    end

    return Leaf.slot (of, paths, expected, at.sidecar)
end

-- Public --------------------------------------------------------------

-- How many reads have been wrapped in a check, which a caller reads either side of a build.
function Emit.wrapped (): number return wrapped end

-- One node and everything under it, with the node's own checks wrapped round the read.
function Emit.emit (of: Ir.Shape, at: Site): (Ir.Write, Ir.Read)
    local write, read = made (of, at)
    return write, if of.tag.checks == nil then read else checked (read, of.tag)
end

--[[
    A check under a field that packs into a word never becomes a read of its own, so the reason it
    parks has to be collected once the whole read is done rather than raised as it happens. One
    shape collecting it beats all of them doing so by a call and a clearing on every field.
]]
function Emit.rooted (read: Ir.Read): Ir.Read
    return function (b: buffer, pos: number, ctx: Types.ValidateContext): (number, any)
        parkedPath = nil
        parkedReason = nil

        local ends, value = read (b, pos, ctx)
        if parkedPath == nil then return ends, value end

        local path, reason = parkedPath, parkedReason
        parkedPath = nil
        parkedReason = nil

        return Log.reject (Catalog.VALIDATE, { pathId = path, reason = reason, at = ends })
    end
end

return table.freeze (Emit)
