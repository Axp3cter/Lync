--!strict
--!optimize 2
-- The descriptor: a schema as text, and the sixty-four bits a handshake carries it as.

local Base = require ("@src/codec/Base")
local Order = require ("@src/shape/Order")
local Protocol = require ("@src/wire/Protocol")
local Wide = require ("@src/kernel/Wide")

local Serial = {}

-- Constants -----------------------------------------------------------

--[[
    Built from hex rather than written as literals, because the basis is past the range a signed
    literal covers and the string form is the one whose value is not parser-dependent.
]]
const BASIS = Wide.parse ("CBF29CE484222325")
const PRIME = Wide.parse ("00000100000001B3")

-- Types ---------------------------------------------------------------

--[[
    What a build carries that a descriptor is written from. A build holds the declaration it was
    made from beside the closures it compiled, and only the declaration is read here, so whatever
    else a build grows never moves the text.
]]
export type Described = { read cell: Base.Cell }

-- The three ways a frame of a definition travels. A caller who declares neither other is reliable.
export type Delivery = "reliable" | "unreliable" | "newest"

--[[
    A definition as the descriptor writes it: its codecs, and every declaration that decides how a
    frame of it travels.
]]
export type Packet = {
    read kind: "packet",
    read of: Described,
    read delivery: Delivery,
    read hz: number?,
    read timestamped: boolean,
}

export type Query = {
    read kind: "query",
    read of: Described,
    read reply: Described,
}

export type Set = {
    read kind: "set",
    read of: Described,
    read keyField: string?,
}

export type Frame = Packet | Query | Set

--[[
    Every text one vocabulary reached, and the number each was first seen under. A rejection carries
    the numbers rather than the words, because composing prose on a decode would pay for it at
    whatever rate the other machine chooses, and the reader that catches one has this to read them
    back out of.
]]
export type Interner = {
    at: { [string]: number },
    texts: { string },
}

-- Private -------------------------------------------------------------

--[[
    A number as text it reads back from. Fourteen digits is what a double usually needs and what
    looks like the number a caller wrote, seventeen is what one always needs, and the round trip
    decides which. Two parameters that differ have to differ here or two schemas share one hash.
]]
local function decimal (value: number): string
    if value == 0 then return "0" end

    local short = string.format ("%.14g", value)
    if tonumber (short) == value then return short end
    return string.format ("%.17g", value)
end

--[[
    A caller's string, quoted and escaped, because a symbol set holds any byte a caller likes and a
    name any character. Left bare, a name holding a comma reads as two names and a field name
    spelling `x=bool();y` reads as two fields, and either way two schemas write one text.
]]
local function quoted (text: string): string
    local slashed = string.gsub (text, "\\", "\\\\")
    local marked = string.gsub (slashed, '"', '\\"')
    return `"{marked}"`
end

-- A parameter holding several values is one slot still, so what it holds is bracketed inside it.
local function listed (parts: { string }): string return `[{table.concat (parts, ",")}]` end

local function vector (of: Vector3): string
    return listed ({ decimal (of.X), decimal (of.Y), decimal (of.Z) })
end

local function colour (of: Color3): string
    return listed ({ decimal (of.R), decimal (of.G), decimal (of.B) })
end

local function labelled (of: { string }): string
    local parts = table.create (#of) :: { string }
    for _, name in of do
        table.insert (parts, quoted (name))
    end
    return listed (parts)
end

local function palette (of: { Color3 }): string
    local parts = table.create (#of) :: { string }
    for _, one in of do
        table.insert (parts, colour (one))
    end
    return listed (parts)
end

--[[
    Every parameter in one order, and the order is the one the surface takes them in, so each kind
    comes out spelled the way a caller wrote it: `int(0,100)`, `str("abc",0,6)`, `vec3(unit,1)`,
    `rotation(axis,[0,1,0],1)`. One list rather than a rule per kind, and it holds for all of them.
]]
const ORDER: { { at: string, write: (any) -> string } } = {
    { at = "form", write = function (of: any): string return of end },
    { at = "symbols", write = quoted },
    { at = "axis", write = vector },
    { at = "min", write = decimal },
    { at = "max", write = decimal },
    { at = "step", write = decimal },
    { at = "field", write = quoted },
    { at = "class", write = quoted },
    { at = "names", write = labelled },
    { at = "colors", write = palette },
}

--[[
    One node's own words: the kind, its parameters, and the marks. Every part comes off the
    declaration and none off what was compiled from it, because two schemas that lower to the same
    bytes are still two schemas.
]]
local function spelled (cell: Base.Cell): string
    local parts = {}
    for _, slot in ORDER do
        local held = (cell.params :: any)[slot.at]
        if held ~= nil then table.insert (parts, slot.write (held)) end
    end

    local out = { cell.kind, "(", table.concat (parts, ","), ")" }

    if cell.marker ~= "none" then
        local rate = if cell.newestHz == nil then "" else `({decimal (cell.newestHz)})`
        table.insert (out, `:{cell.marker}{rate}`)
    end
    for _ = 1, #cell.validates do
        table.insert (out, ":validate")
    end

    return table.concat (out)
end

-- A whole codec as text: a node's own words, and then its children under theirs.
local function written (cell: Base.Cell): string
    local children = cell.children
    if children == nil then return spelled (cell) end

    local out = { spelled (cell), "{" }
    for _, name in Order.names (children) do
        table.insert (out, `{quoted (name)}={written (children[name])}`)
        table.insert (out, ";")
    end
    table.insert (out, "}")

    return table.concat (out)
end

-- Public --------------------------------------------------------------

function Serial.describe (of: Described): string return written (of.cell) end

-- A definition as its own text, printed by a handle and carried by a namespace.
function Serial.frame (of: Frame): string
    if of.kind == "packet" then
        local rate = decimal (if of.hz == nil then 0 else of.hz)
        return `packet[{of.delivery},{rate},{of.timestamped}]({written (of.of.cell)})`
    end

    if of.kind == "query" then return `query({written (of.of.cell)})({written (of.reply.cell)})` end

    local key = if of.keyField == nil then "" else quoted (of.keyField)
    return `set[{key}]({written (of.of.cell)})`
end

--[[
    A namespace as the one text two machines compare: the version, the name, and every definition
    under the name it is reached by, in the order both of them sort those names into. The version
    leads, so the hash binds the protocol version for free and a bump fails every handshake with no
    bytes spent saying so.
]]
function Serial.namespace (name: string, of: { [string]: Frame }): string
    local out = { `{Protocol.VERSION}:{name}` }
    for _, held in Order.names (of) do
        table.insert (out, ";")
        table.insert (out, `{held}={Serial.frame (of[held])}`)
    end
    return table.concat (out)
end

function Serial.interner (): Interner return { at = {}, texts = {} } end

--[[
    A text, under the number it is reached by. The same text twice is the same number: a schema
    names one expectation at a hundred fields and a table holding a hundred copies of it would be a
    hundred strings a place keeps for the life of the session.
]]
function Serial.intern (of: Interner, text: string): number
    local held = of.at[text]
    if held ~= nil then return held end

    local id = #of.texts + 1
    of.texts[id] = text
    of.at[text] = id
    return id
end

-- Where a child is, spelled from where its parent is.
function Serial.under (at: string, name: string): string return `{at}.{name}` end

-- Where a node is and what it wanted, as the two numbers a rejection carries.
function Serial.tagged (
    paths: Interner,
    expected: Interner,
    at: string,
    cell: Base.Cell
): (number, number)
    return Serial.intern (paths, at), Serial.intern (expected, spelled (cell))
end

--[[
    A byte crosses into the carrier's domain before it is folded, because the exclusive or and the
    multiply both refuse a bare number rather than lifting one. It is taken into a local first
    because `string.byte` is typed as answering a variadic, and the crossing takes one number.
]]
function Serial.hash (text: string): Wide.Word
    local h = BASIS

    for index = 1, #text do
        local byte = string.byte (text, index)
        h = Wide.mul (Wide.bxor (h, Wide.of (byte)), PRIME)
    end
    return h
end

return table.freeze (Serial)
