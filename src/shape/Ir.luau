--!strict
--!optimize 2
-- The closed set of things the emitter knows how to write, and the one place each is built.

local Base = require ("@src/codec/Base")
local Bits = require ("@src/kernel/Bits")
local Bytes = require ("@src/wire/Bytes")
local Grid = require ("@src/shape/Grid")
local Protocol = require ("@src/wire/Protocol")
local Types = require ("@src/Types")
local Words = require ("@src/shape/Words")

local Ir = {}

-- Constants -----------------------------------------------------------

const BYTE = Protocol.BYTE_BITS

-- Shared by every group holding no dissolved record, since one frozen empty table is enough.
const NO_NESTS = table.freeze ({} :: { Nest })

-- Types ---------------------------------------------------------------

export type Op =
    "word"
    | "wide"
    | "f32"
    | "f64"
    | "vlq"
    | "vli"
    | "bytes"
    | "unknown"
    | "run"
    | "list"
    | "pairs"
    | "group"
    | "apart"
    | "opt"
    | "branch"
    | "slot"
    | "xform"

--[[
    What a rejection at this place names, as the two indices the serializer interned it under.
    Indices and not text, since a decode composing prose would pay for it on a path a hostile
    client sets the rate of, and the boundary that catches the raise reads them back.
]]
export type Tag = {
    read pathId: number,
    read expectId: number,
    read checks: { Base.Validate }?,
}

-- The pair every op exists to become.
export type Write = (b: buffer, pos: number, value: any) -> number
export type Read = (b: buffer, pos: number, ctx: Types.ValidateContext) -> (number, any)

-- The instances that ride beside a frame, the slot each takes, and whether the schema names any.
export type Sidecar = {
    refs: { Instance },
    slotOf: { [Instance]: number },
    bears: boolean,
}

-- A record that dissolved into the one holding it, and the key its fields are read out of.
export type Nest = {
    read key: string,
    read under: number?,
    read allow: { [string]: boolean },
    read tag: Tag,
}

-- The inclusive bounds a count runs between, a ranged int of no bits at all where the two meet.
export type Span = {
    read min: number,
    read max: number,
}

--[[
    Where a run of leaves comes from, and what it goes back to. A join of one leaf whose grid is the
    whole mapping carries no pair, which is every ordinary numeric field. Everything else carries
    one, since its leaves come out of a single computation that asking one at a time would run once
    per component kept.
]]
export type Join = {
    read at: number,
    read count: number,
    read key: string?,
    read nest: number?,
    read tag: Tag,
    read pull: ((value: any, into: { number }, at: number) -> boolean)?,
    read push: ((from: { number }, at: number) -> any)?,
}

--[[
    A bit region and the windows it was cut into. The one node whose size is not a whole number of
    bytes, which is why it is the one that says how many bits it is.
]]
export type Word = {
    read op: "word",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read bits: number,
    read plan: { Words.Word },
    read leaves: { Grid.Grid },
    read joins: { Join },
}

export type Wide = {
    read op: "wide",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read grid: Grid.Grid,
}

-- A payload of nothing, which is the whole of a call whose happening is what it says.
export type None = {
    read op: "none",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
}

export type Float = {
    read op: "f32" | "f64",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
}

export type Varint = {
    read op: "vlq" | "vli",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
}

export type Bytes = {
    read op: "bytes",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read count: Span,
    read alphabet: string?,
    read form: "string" | "buffer",
}

--[[
    A value the schema does not describe, which describes itself instead. Every part carries a tag,
    so nothing about it can be planned: never one width, never landing on a grid, and bounded only
    by the room the declaration gave it.
]]
export type Unknown = {
    read op: "unknown",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read count: Span,
}

export type Run = {
    read op: "run",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read count: Span,
    read elem: Grid.Grid,
}

export type List = {
    read op: "list",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read count: Span,
    read elem: Shape,
}

-- A count and then that many pairs, each a key and then the value under it.
export type Pairs = {
    read op: "pairs",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read count: Span,
    read key: Shape,
    read value: Shape,
    read runs: Grid.Grid?,
    read keyed: Grid.Grid?,
}

--[[
    One thing after the region, and the field it is read off. Absent where the value handed to the
    group is the part's own, which is a definition whose whole payload is one variable thing, and at
    most one part of a group is keyless for the same reason at most one join is.
]]
export type Part = {
    read key: string?,
    read nest: number?,
    read of: Shape,
}

export type Group = {
    read op: "group",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read allow: { [string]: boolean }?,
    read word: Word?,
    read parts: { Part },
    read nests: { Nest },
}

export type Opt = {
    read op: "opt",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read bit: number,
    read inner: Shape,
}

--[[
    A tag and the arms it chooses between. The field is the one the tag rides in, because a variant
    is a record and its name is a field of it rather than something beside it, and the names are in
    the order the arms are, which is canonical.
]]
export type Branch = {
    read op: "branch",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read field: string,
    read names: { string },
    read tagWidth: number,
    read arms: { Shape },
}

export type Slot = {
    read op: "slot",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read class: string?,
}

export type Xform = {
    read op: "xform",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read inner: Shape,
    read lift: (wire: any) -> any,
    read lower: (domain: any) -> any,
}

--[[
    Every node there is. Closed, so the emitter's dispatch is exhaustive by the checker, and one
    concrete record per op, so reading a field the op does not have is a compile error rather than a
    nil at whatever rate a frame arrives.
]]
export type Shape =
    None
    | Word
    | Wide
    | Float
    | Varint
    | Bytes
    | Unknown
    | Run
    | List
    | Pairs
    | Group
    | Apart
    | Opt
    | Branch
    | Slot
    | Xform

-- Private -------------------------------------------------------------

--[[
    The bits a count is written as, which is none where the bounds meet. A caller who declared one
    length spends nothing saying it again, and the decoder has the number without reading one.
]]
local function counted (of: Span): number return Bits.width (of.max - of.min) end

-- Public --------------------------------------------------------------

function Ir.word (tag: Tag, plan: { Words.Word }, leaves: { Grid.Grid }, joins: { Join }): Word
    local bits = 0
    for _, grid in leaves do
        bits += grid.width
    end

    local bytes = 0
    for _, one in plan do
        bytes += one.bytes
    end

    return table.freeze ({
        op = "word" :: "word",
        fixed = true,
        maxBytes = bytes,
        tag = tag,
        bits = bits,
        plan = table.freeze (plan),
        leaves = table.freeze (leaves),
        joins = table.freeze (joins),
    })
end

--[[
    One fixed field too wide for the run accumulator to pack, written as whole bytes of its own. The
    grid's width is the value's and the node's is what it costs, and past twenty-four bits those are
    two different numbers.
]]
function Ir.wide (tag: Tag, grid: Grid.Grid): Wide
    return table.freeze ({
        op = "wide" :: "wide",
        fixed = true,
        maxBytes = Bytes.whole (grid.width),
        tag = tag,
        grid = grid,
    })
end

function Ir.float (tag: Tag, wide: boolean): Float
    return table.freeze ({
        op = (if wide then "f64" else "f32") :: "f64",
        fixed = true,
        maxBytes = if wide then 8 else 4,
        tag = tag,
    })
end

--[[
    A varint. Never fixed, even where a caller's values would always fit one group, because what
    decides the length is the value and a shape is what is known before there is one.
]]
function Ir.varint (tag: Tag, signed: boolean): Varint
    return table.freeze ({
        op = (if signed then "vli" else "vlq") :: "vli",
        fixed = false,
        maxBytes = Protocol.VARINT_GROUPS,
        tag = tag,
    })
end

function Ir.none (tag: Tag): None
    return table.freeze ({ op = "none" :: "none", fixed = true, maxBytes = 0, tag = tag })
end

-- A string or a buffer, as its count and then its bytes.
function Ir.bytes (tag: Tag, count: Span, form: "string" | "buffer", alphabet: string?): Bytes
    local width = if alphabet == nil then BYTE else Bits.width (#alphabet - 1)

    return table.freeze ({
        op = "bytes" :: "bytes",
        fixed = count.min == count.max,
        maxBytes = Bytes.whole (counted (count)) + Bytes.whole (count.max * width),
        tag = tag,
        count = table.freeze (count),
        alphabet = alphabet,
        form = form,
    })
end

-- A value that says what it is as it goes.
function Ir.unknown (tag: Tag, count: Span): Unknown
    return table.freeze ({
        op = "unknown" :: "unknown",
        fixed = false,
        maxBytes = count.max + Protocol.UNKNOWN_SLACK,
        tag = tag,
        count = table.freeze (count),
    })
end

-- Elements of one width, lying end to end with no padding between them.
function Ir.run (tag: Tag, count: Span, elem: Grid.Grid): Run
    return table.freeze ({
        op = "run" :: "run",
        fixed = count.min == count.max,
        maxBytes = Bytes.whole (counted (count)) + Bytes.whole (count.max * elem.width),
        tag = tag,
        count = table.freeze (count),
        elem = elem,
    })
end

--[[
    Elements the run cannot take, each written whole and each starting on a byte. The worst case
    multiplies the element's bytes rather than its bits, because every element pays its own
    alignment whether or not the count ever varies.
]]
function Ir.list (tag: Tag, count: Span, elem: Shape): List
    return table.freeze ({
        op = "list" :: "list",
        fixed = count.min == count.max and elem.fixed,
        maxBytes = Bytes.whole (counted (count)) + count.max * elem.maxBytes,
        tag = tag,
        count = table.freeze (count),
        elem = elem,
    })
end

--[[
    Whether the value is one reading on a grid, which is what lets every value lie end to end in
    the bits it takes rather than each opening a byte. Asked where the width is worked out, so
    what a shape promises to weigh and what it writes cannot answer this differently.
]]
local function running (value: Shape): Grid.Grid?
    local of: any = value
    if of.op ~= "word" or #of.leaves ~= 1 or #of.joins ~= 1 then return nil end

    local join = of.joins[1]
    if join.key ~= nil or join.pull ~= nil or join.push ~= nil or join.count ~= 1 then
        return nil
    end

    return of.leaves[1]
end

--[[
    A map, as its two halves and what it may hold between them.

    The worst case multiplies the pair rather than either half, since a map of no pairs writes its
    count and nothing else and a map of many writes both of them that many times.
]]
function Ir.pairs (tag: Tag, count: Span, key: Shape, value: Shape): Pairs
    local runs = running (value)
    local values = if runs == nil
        then count.max * value.maxBytes
        else Bytes.whole (count.max * runs.width)

    local keyed = running (key)
    local keys = if keyed == nil
        then count.max * key.maxBytes
        else Bytes.whole (count.max * keyed.width)

    return table.freeze ({
        op = "pairs" :: "pairs",
        fixed = count.min == count.max and key.fixed and value.fixed,
        maxBytes = Bytes.whole (counted (count)) + keys + values,
        tag = tag,
        count = table.freeze (count),
        key = key,
        value = value,
        runs = runs,
        keyed = keyed,
    })
end

-- A region sequence: the bit region as one word, then everything after it in wire order.
function Ir.group (
    tag: Tag,
    word: Word?,
    parts: { Part },
    nests: { Nest }?,
    allow: { [string]: boolean }?
): Group
    local fixed = true
    local maxBytes = if word == nil then 0 else word.maxBytes

    for _, part in parts do
        maxBytes += part.of.maxBytes
        if part.of.fixed then continue end
        fixed = false
    end

    return table.freeze ({
        op = "group" :: "group",
        fixed = fixed,
        maxBytes = maxBytes,
        tag = tag,
        allow = if allow == nil then nil else table.freeze (allow),
        word = word,
        parts = table.freeze (parts),
        nests = if nests == nil then NO_NESTS else table.freeze (nests),
    })
end

--[[
    The computation that puts a value back together out of the parts it came apart into.

    Going out is a lookup and coming back is a call, which is the engine's asymmetry rather than a
    choice here: its datatypes carry their parts as properties and are built whole or not at all.
]]
export type Build = (from: { any }) -> any

-- A value that comes apart into whole-byte fields.
export type Apart = {
    read op: "apart",
    read fixed: boolean,
    read maxBytes: number,
    read tag: Tag,
    read engine: string,
    read keys: { string },
    read parts: { Shape },
    read push: Build,
}

-- A value and its parts, in the order they are written.
function Ir.apart (tag: Tag, engine: string, keys: { string }, parts: { Shape }, push: Build): Apart
    local fixed = true
    local maxBytes = 0

    for _, of in parts do
        maxBytes += of.maxBytes
        if of.fixed then continue end
        fixed = false
    end

    return table.freeze ({
        op = "apart" :: "apart",
        fixed = fixed,
        maxBytes = maxBytes,
        tag = tag,
        engine = engine,
        keys = table.freeze (keys),
        parts = table.freeze (parts),
        push = push,
    })
end

--[[
    A value that may not be there, and the bit in the enclosing region that says so. The bit is
    named by the leaf it is rather than read back out of the buffer, because the group has already
    decoded the whole region into locals by the time this is reached.
]]
function Ir.opt (tag: Tag, bit: number, inner: Shape): Opt
    return table.freeze ({
        op = "opt" :: "opt",
        fixed = false,
        maxBytes = inner.maxBytes,
        tag = tag,
        bit = bit,
        inner = inner,
    })
end

--[[
    A tag and the arm it names. The width is the ranged int the arm count needs rather than a number
    handed in, because the two could not disagree and one of them would be the copy.
]]
function Ir.branch (tag: Tag, field: string, names: { string }, arms: { Shape }): Branch
    local worst = 0
    for _, arm in arms do
        worst = math.max (worst, arm.maxBytes)
    end

    local tagWidth = Bits.width (#arms - 1)

    return table.freeze ({
        op = "branch" :: "branch",
        fixed = false,
        maxBytes = Bytes.whole (tagWidth) + worst,
        tag = tag,
        field = field,
        names = table.freeze (names),
        tagWidth = tagWidth,
        arms = table.freeze (arms),
    })
end

--[[
    An instance, as the index of the slot it takes in the frame's sidecar. Its presence bit is not
    here: one that may be absent is this node inside an `opt`, which is what the surface says about
    every other value that may be absent.
]]
function Ir.slot (tag: Tag, class: string?): Slot
    return table.freeze ({
        op = "slot" :: "slot",
        fixed = false,
        maxBytes = Protocol.VARINT_GROUPS,
        tag = tag,
        class = class,
    })
end

--[[
    A value on its way to and from the one the wire carries. It is the same bytes as its inner node
    and says so by taking both facts off it, which is what makes a transform free to the layout and
    impossible to see in a golden.
]]
function Ir.xform (
    tag: Tag,
    inner: Shape,
    lift: (wire: any) -> any,
    lower: (domain: any) -> any
): Xform
    return table.freeze ({
        op = "xform" :: "xform",
        fixed = inner.fixed,
        maxBytes = inner.maxBytes,
        tag = tag,
        inner = inner,
        lift = lift,
        lower = lower,
    })
end

return table.freeze (Ir)
