--!strict
--!optimize 2
-- What a start will take: the declaration a definition is, and every test made of one.

local Base = require ("@src/codec/Base")
local Folds = require ("@src/shape/Folds")
local Grid = require ("@src/shape/Grid")
local Joins = require ("@src/shape/Joins")
local Log = require ("@src/kernel/Log")
local Order = require ("@src/shape/Order")
local Protocol = require ("@src/wire/Protocol")
local Scalars = require ("@src/codec/Scalars")
local Serial = require ("@src/shape/Serial")
local Types = require ("@src/Types")

local Legality = {}

-- Constants -----------------------------------------------------------

-- What a set replicates, and how many of its fields one dirty mask covers.
const RECORD: Base.Kind = "struct"
const FIELDS = Protocol.MAX_FIELDS

-- The widest leaf a bit run carries, which is the line one computation may not fall across.
const CEILING = Protocol.BIT_CEILING

-- How far a double counts exactly, which is what a grid's span has to stay under.
const REACH = Protocol.EXACT

-- What one fire of the lossy lane carries, which is the ceiling a block on it stays under.
const CAP = Protocol.UNRELIABLE_CAP

-- The punctuation the descriptor grammar separates a namespace with, which no name may hold.
const SPELLED = table.freeze ({ ";", "=" })

-- Types ---------------------------------------------------------------

--[[
    Where a definition was written, which is the one fact a refusal here carries that a caller
    cannot work out for themselves. A start legality is raised inside a compile and a compile runs a
    long way from the line that declared the thing, so a message without this says a schema is wrong
    and leaves finding it to a search.
]]
export type Site = { read file: string, read line: number }

-- A definition as its caller declared it, which is what they said rather than what it means.
export type Packet = {
    read kind: "packet",
    read of: Types.Codec<any>,
    read isUnreliable: boolean,
    read isNewest: boolean,
    read hz: number?,
    read isTimestamped: boolean,
    read at: Site,
}

export type Query = {
    read kind: "query",
    read of: Types.Codec<any>,
    read reply: Types.Codec<any>,
    read at: Site,
}

export type Set = {
    read kind: "set",
    read of: Types.Codec<any>,
    read keyField: string?,
    read at: Site,
}

export type Declared = Packet | Query | Set

-- Private -------------------------------------------------------------

-- A refusal, as the one line whoever wrote the schema reads.
local function refuse (name: string, at: Site, said: string): never
    return Log.refuse (`{name} {said}, declared at {at.file}:{at.line}`)
end

-- The first node under here carrying a state marker, and the marker it carries.
local function marked (of: Base.Cell, at: string): (string?, Base.Marker)
    if of.marker ~= "none" then return at, of.marker end

    local children = of.children
    if children == nil then return nil, "none" end

    for _, name in Order.names (children) do
        local where, mark = marked (children[name], Serial.under (at, name))
        if where ~= nil then return where, mark end
    end
    return nil, "none"
end

-- How many steps a declaration's grid runs to, where a division decides that and not a count.
local function points (of: Base.Cell): number?
    local kind, params = of.kind, of.params

    if kind == "int" then return (params.max :: number) - (params.min :: number) end
    if kind == "quant" then
        return ((params.max :: number) - (params.min :: number)) / (params.step :: number)
    end
    if kind == "angle" then return Scalars.TURN / (params.step :: number) end
    return nil
end

-- Whether one computation's leaves fall either side of the bit run's ceiling.
local function straddles (of: Base.Cell): boolean
    local fold = Folds.fold (of)
    if fold == nil then return false end

    local under, over = false, false
    for _, grid in fold.leaves do
        if grid.width > CEILING then
            over = true
        else
            under = true
        end
    end
    return under and over
end

-- What one node declares that its constructor could not refuse, as the clause a message reads.
local function imprecise (of: Base.Cell, at: string): string?
    local span = points (of)
    if span ~= nil and span >= REACH then
        return `declares {at} over {span} steps, which is past what a double counts exactly`
    end

    if of.kind == "angle" then
        local step = of.params.step :: number
        if not Grid.divides (Scalars.TURN, step) then
            return `declares {at} to {step} degrees, which does not divide a turn`
        end
    end

    if not straddles (of) then return nil end
    return `declares {at} to a precision whose parts fall either side of {CEILING} bits`
end

-- The first node with something wrong, in the one order a walk of this library visits children in.
local function imprecision (of: Base.Cell, at: string): string?
    local said = imprecise (of, at)
    if said ~= nil then return said end

    local children = of.children
    if children == nil then return nil end

    for _, name in Order.names (children) do
        local under = imprecision (children[name], Serial.under (at, name))
        if under ~= nil then return under end
    end
    return nil
end

-- A tree carrying no state between frames, which is every tree outside a set.
local function stateless (name: string, at: Site, what: string, of: Base.Cell, root: string)
    local where, mark = marked (of, root)
    if where ~= nil then
        refuse (name, at, `declares {mark} at {where}, and {what} keeps nothing to differ from`)
    end

    local why = imprecision (of, root)
    if why == nil then return end
    refuse (name, at, why)
end

-- A record a set replicates, and everything about it that only a set decides.
local function replicated (name: string, at: Site, of: Set)
    local cell = Base.cell (of.of)
    if cell.kind ~= RECORD then
        refuse (name, at, `replicates a {cell.kind}, and a set replicates records`)
    end

    local fields = cell.children :: { [string]: Base.Cell }
    local names = Order.names (fields)
    local reach = #names

    if reach == 0 then refuse (name, at, "replicates a record of no fields") end
    if reach > FIELDS then
        refuse (name, at, `replicates {reach} fields, and one dirty mask covers {FIELDS}`)
    end

    for _, field in names do
        local children = fields[field].children
        if children == nil then continue end

        local under = Serial.under (name, field)
        for _, inner in Order.names (children) do
            local where, mark = marked (children[inner], Serial.under (under, inner))
            if where == nil then continue end
            refuse (name, at, `declares {mark} at {where}, and a set deltas its own fields`)
        end
    end

    local why = imprecision (cell, name)
    if why ~= nil then refuse (name, at, why) end

    local key = of.keyField
    if key == nil then return end

    local held = fields[key]
    if held == nil then
        refuse (name, at, `is keyed by {key}, which its record does not declare`)
    end

    if held.marker == "newest" then
        refuse (name, at, `is keyed by {key} and declares newest on it, and a key has to arrive`)
    end

    if Joins.grid (held) ~= nil then return end
    refuse (name, at, `is keyed by {key}, and its {held.kind} is not one number to partition by`)
end

-- Public --------------------------------------------------------------

-- Which of the three lanes a packet asked for.
function Legality.delivery (of: Packet): Serial.Delivery
    if of.isUnreliable then return "unreliable" end
    if of.isNewest then return "newest" end
    return "reliable"
end

-- A block that has to fit one fire, refused where it cannot.
function Legality.block (name: string, of: Packet, bytes: number)
    local lane = Legality.delivery (of)
    if lane == "reliable" or bytes <= CAP then return end

    refuse (
        name,
        of.at,
        `is {lane} and its widest block is {bytes} bytes, past the {CAP} one fire carries`
    )
end

-- What a query's two halves are called, wherever one of them has to be named apart from the other.
Legality.REQUEST = "request"
Legality.RESPONSE = "response"

-- Why a name is one the descriptor cannot spell back, or nothing.
function Legality.named (name: string): string?
    for _, mark in SPELLED do
        if string.find (name, mark, 1, true) == nil then continue end
        return `holds a {mark}, which is what a descriptor separates its own names with`
    end
    return nil
end

-- One definition, refused on the first thing wrong with it.
function Legality.definition (name: string, of: Declared)
    local at = of.at

    local why = Legality.named (name)
    if why ~= nil then refuse (name, at, why) end

    if of.kind == "packet" then
        if of.isUnreliable and of.isNewest then
            refuse (name, at, "declares two ways of delivering itself, unreliable and newest")
        end
        stateless (name, at, "a packet", Base.cell (of.of), name)
        return
    end

    if of.kind == "query" then
        stateless (name, at, "a query", Base.cell (of.of), Serial.under (name, Legality.REQUEST))
        local reply = Base.cell (of.reply)
        stateless (name, at, "a query", reply, Serial.under (name, Legality.RESPONSE))
        return
    end

    replicated (name, at, of)
end

return table.freeze (Legality)
