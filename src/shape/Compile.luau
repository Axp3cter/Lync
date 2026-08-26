--!strict
--!optimize 2
-- A namespace of declarations as the frozen records every layer above reads it by.

local Base = require ("@src/codec/Base")
local Frames = require ("@src/shape/Frames")
local Legality = require ("@src/shape/Legality")
local Log = require ("@src/kernel/Log")
local Order = require ("@src/shape/Order")
local Serial = require ("@src/shape/Serial")
local Shape = require ("@src/shape")
local Types = require ("@src/Types")
local Wide = require ("@src/kernel/Wide")

local Compile = {}

-- Constants -----------------------------------------------------------

-- What a template holds in every field, which is a place rather than a value.
const PLACE = false

-- Types ---------------------------------------------------------------

-- What one definition costs, as the two numbers a caller of it can want.
export type Packet = {
    read id: number,
    read name: string,
    read kind: "packet",
    read maxBytes: number,
    read file: string,
    read line: number,
    read built: Shape.Built,
    read head: Frames.Head,
    read blockBytes: number,
    read delivery: Serial.Delivery,
    read hz: number?,
    read timestamped: boolean,
}

--[[
    A query holds two builds and one id, and its response is that id and one. A frame carries a
    single axis and no kind bit, so which half arrived is read off whether the id is the one the
    record carries, a comparison the router already holds both sides of.
]]
export type Query = {
    read id: number,
    read name: string,
    read kind: "query",
    read maxBytes: number,
    read file: string,
    read line: number,
    read request: Shape.Built,
    read response: Shape.Built,
    read asks: Frames.Head,
    read answers: Frames.Head,
    read blockBytes: number,
}

--[[
    A set is its fields, so what it carries is per field and in one order. The record's own cell is
    here and its own build is not, since a section never writes a whole record and the cell is all
    the descriptor ever wanted. Which fields may hold nothing and which may only climb are beside
    the builds, because reading either off a cell at the call would be `state` reading a codec.
]]
export type Set = {
    read id: number,
    read name: string,
    read kind: "set",
    read maxBytes: number,
    read file: string,
    read line: number,
    read cell: Base.Cell,
    read head: Frames.Head,
    read stream: Frames.Head,
    read keyField: string?,
    read keyIndex: number?,
    read fieldNames: { string },
    read fieldIndex: { [string]: number },
    read fieldBuilt: { Shape.Built },
    read fieldCount: number,
    read newestFields: { number },
    read optionalFields: { boolean },
    read climbingFields: { boolean },
    read climbs: boolean,
    read template: { [string]: any },
    read site: Shape.Site,
}

-- The marker vocabulary, re-exported rather than reached for.
export type Marker = Base.Marker

export type Def = Packet | Query | Set

--[[
    A namespace, compiled. `count` is how many ids were handed out rather than how many definitions
    there are, because a defId is a ranged int over exactly that and a query took two.
]]
export type Compiled = {
    read space: string,
    read descriptor: string,
    read hash: Wide.Word,
    read count: number,
    read list: { Def },
    read byName: { [string]: Def },
    read byId: { [number]: Def },
}

-- A set's fields, as the four arrays a column walk reads and the bytes one record comes to.
type Fields = {
    names: { string },
    index: { [string]: number },
    built: { Shape.Built },
    newest: { number },
    optional: { boolean },
    climbs: { boolean },
    template: { [string]: any },
    site: Shape.Site,
    bytes: number,
}

-- Private -------------------------------------------------------------

-- A handle as the declaration it carries.
local function declared (of: Types.Definition): Legality.Declared return of :: any end

-- A set's fields, in the order their columns are indexed by.
local function columns (name: string, cell: Base.Cell): Fields
    local fields = cell.children :: { [string]: Base.Cell }
    local names = Order.names (fields)
    local reach = #names

    local built = table.create (reach) :: { Shape.Built }
    local place: { [string]: number } = {}
    local newest: { number } = {}
    local optional = table.create (reach) :: { boolean }
    local climbs = table.create (reach) :: { boolean }
    local template: { [string]: any } = {}
    local bytes = 0

    --[[
        One site for the whole set rather than one a field, everything in it numbered from
        nothing. A section is one block over every field and a boundary holds the definition, so
        fields numbering into tables of their own would each start again at one.
    ]]
    local site: Shape.Site = {
        paths = Serial.interner (),
        expected = Serial.interner (),
        sidecar = { refs = {}, slotOf = {}, bears = false },
    }

    for index, field in names do
        local held = fields[field]
        local one = Shape.build (Base.codec (held), Serial.under (name, field), site)

        built[index] = one
        place[field] = index
        bytes += one.maxBytes
        template[field] = PLACE
        optional[index] = held.kind == "optional"
        climbs[index] = held.marker == "monotonic"

        if held.marker == "newest" then table.insert (newest, index) end
    end

    return {
        names = table.freeze (names),
        index = table.freeze (place),
        built = table.freeze (built),
        newest = table.freeze (newest),
        optional = table.freeze (optional),
        climbs = table.freeze (climbs),
        template = table.freeze (template),
        site = site,
        bytes = bytes,
    }
end

-- One declaration as the record it becomes, at the id and under the count it was given.
local function made (name: string, id: number, over: number, of: Legality.Declared): Def
    local at = of.at

    if of.kind == "packet" then
        local built = Shape.build (of.of, name)
        local lane = Legality.delivery (of)

        --[[
            A newest packet's block is a different form rather than the same one differently filled:
            it carries a sequence and never a continuation, because its senders coalesce to one
            value before it is sequenced and a bit saying so would never be anything else.
        ]]
        local head = if lane == "newest"
            then Frames.newest (over, of.isTimestamped)
            else Frames.packet (over, of.isTimestamped)

        local bytes = Frames.block (head, built.maxBytes)
        Legality.block (name, of, bytes)

        return table.freeze ({
            id = id,
            name = name,
            kind = "packet" :: "packet",
            maxBytes = built.maxBytes,
            file = at.file,
            line = at.line,
            built = built,
            head = head,
            blockBytes = bytes,
            delivery = lane,
            hz = of.hz,
            timestamped = of.isTimestamped,
        })
    end

    --[[
        A query is two blocks at two ids, so it is two heads, and what one costs is the wider of
        them. Neither is held to a ceiling: both ride the reliable lane, which is never split and is
        bounded by the budget rather than by what one fire carries.
    ]]
    if of.kind == "query" then
        local request = Shape.build (of.of, Serial.under (name, Legality.REQUEST))
        local response = Shape.build (of.reply, Serial.under (name, Legality.RESPONSE))

        local asks = Frames.request (over)
        local answers = Frames.response (over)

        return table.freeze ({
            id = id,
            name = name,
            kind = "query" :: "query",
            maxBytes = math.max (request.maxBytes, response.maxBytes),
            file = at.file,
            line = at.line,
            request = request,
            response = response,
            asks = asks,
            answers = answers,
            blockBytes = math.max (
                Frames.block (asks, request.maxBytes),
                Frames.block (answers, response.maxBytes)
            ),
        })
    end

    local cell = Base.cell (of.of)
    local held = columns (name, cell)
    local key = of.keyField

    return table.freeze ({
        id = id,
        name = name,
        kind = "set" :: "set",
        maxBytes = held.bytes,
        file = at.file,
        line = at.line,
        cell = cell,
        head = Frames.section (over),
        stream = Frames.stream (over, #held.names),
        keyField = key,
        keyIndex = if key == nil then nil else held.index[key],
        fieldNames = held.names,
        fieldIndex = held.index,
        fieldBuilt = held.built,
        site = held.site,
        fieldCount = #held.names,
        newestFields = held.newest,
        optionalFields = held.optional,
        climbingFields = held.climbs,
        climbs = next (held.climbs) ~= nil,
        template = held.template,
    })
end

-- A definition as the descriptor writes it.
local function framed (of: Def): Serial.Frame
    if of.kind == "packet" then
        return {
            kind = "packet",
            of = of.built,
            delivery = of.delivery,
            hz = of.hz,
            timestamped = of.timestamped,
        }
    end

    if of.kind == "query" then return { kind = "query", of = of.request, reply = of.response } end
    return { kind = "set", of = { cell = of.cell }, keyField = of.keyField }
end

-- Public --------------------------------------------------------------

-- A namespace's declarations, refused or compiled, as one frozen record.
function Compile.build (space: string, specs: Types.Definitions): Compiled
    local why = Legality.named (space)
    if why ~= nil then Log.refuse (`the namespace {space} {why}`) end

    local names = Order.names (specs)

    -- How many ids there are, before any of them is handed out.
    local over = 0
    for _, name in names do
        over += if declared (specs[name]).kind == "query" then 2 else 1
    end

    local list = table.create (#names) :: { Def }
    local byName: { [string]: Def } = {}
    local byId: { [number]: Def } = {}
    local frames: { [string]: Serial.Frame } = {}

    local at = 0
    for _, name in names do
        local of = declared (specs[name])
        Legality.definition (name, of)

        local def = made (name, at, over, of)
        table.insert (list, def)
        byName[name] = def
        frames[name] = framed (def)

        byId[at] = def
        if def.kind ~= "query" then
            at += 1
            continue
        end

        byId[at + 1] = def
        at += 2
    end

    local descriptor = Serial.namespace (space, frames)

    return table.freeze ({
        space = space,
        descriptor = descriptor,
        hash = Serial.hash (descriptor),
        count = over,
        list = table.freeze (list),
        byName = table.freeze (byName),
        byId = table.freeze (byId),
    })
end

return table.freeze (Compile)
