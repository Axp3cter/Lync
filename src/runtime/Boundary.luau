--!strict
--!optimize 2
-- The trust split: bytes from a client are hostile, bytes from the server are this library's own.

local Catalog = require ("@src/kernel/Catalog")
local Compile = require ("@src/shape/Compile")
local Log = require ("@src/kernel/Log")
local Serial = require ("@src/shape/Serial")
local Tally = require ("@src/kernel/Tally")
local Types = require ("@src/Types")

local Boundary = {}

-- Constants -----------------------------------------------------------

-- What a drop is on each lane, which is the whole of what the trust split comes to afterwards.
const HOSTILE: Types.LogKind = "warn"
const TRUSTED: Types.LogKind = "error"

-- Types ---------------------------------------------------------------

-- What a validate is handed, as the record this module keeps rather than the read one it is.
export type Context = {
    player: Player?,
    now: number,
    last: number?,
}

-- The two tables a rejection's numbers are read back through.
export type Names = {
    read paths: Serial.Interner,
    read expected: Serial.Interner,
}

-- One link's boundary: the two contexts, the arrival stamps, and whether this frame has a cursor.
export type Boundary = {
    read name: string,
    read tally: Tally.Tally,
    read hostile: Context,
    read trusted: Context,
    read stamps: { [Player]: { [number]: number } },
    read heard: { [number]: number },
    ctx: Context,
    live: boolean,
    took: boolean,
}

-- Private -------------------------------------------------------------

-- An empty context, which is what a link holds two of for as long as it is open.
local function context (): Context return { player = nil, now = 0, last = nil } end

-- What one sender's definitions were last heard at, made the first time they are heard at all.
local function marks (of: Boundary, from: Player): { [number]: number }
    local held = of.stamps[from]
    if held ~= nil then return held end

    held = {}
    of.stamps[from] = held
    return held
end

-- Where the reader got to, for a failure that can be asked.
local function resumed (thrown: unknown): number?
    if typeof (thrown) ~= "table" then return nil end

    local rejection = thrown :: Log.Rejection
    if rejection.code ~= Catalog.VALIDATE then return nil end

    local at = rejection.facts.at
    return if typeof (at) == "number" then at else nil
end

-- A rejection's numbers as the words they were interned from.
local function diagnosed (thrown: unknown, names: Names, about: Log.Facts)
    if typeof (thrown) ~= "table" then return end

    local facts = (thrown :: Log.Rejection).facts
    local path = facts.pathId
    local expected = facts.expectId

    if typeof (path) == "number" then about.path = names.paths.texts[path] end
    if typeof (expected) == "number" then about.expected = names.expected.texts[expected] end
end

-- Public --------------------------------------------------------------

-- One link's boundary, before anything has arrived.
function Boundary.new (name: string, tally: Tally.Tally): Boundary
    local hostile = context ()

    return {
        name = name,
        tally = tally,
        hostile = hostile,
        trusted = context (),
        stamps = {},
        heard = {},
        ctx = hostile,
        live = true,
        took = false,
    }
end

-- A frame arriving, and the context every payload in it is read under.
function Boundary.opened (of: Boundary, from: Player?, now: number)
    local ctx = if from == nil then of.trusted else of.hostile

    ctx.player = from
    ctx.now = now
    ctx.last = nil

    of.ctx = ctx
    of.live = true
end

-- One definition heard from one sender, stamped whether or not what follows decodes.
function Boundary.stamped (of: Boundary, from: Player?, id: number, now: number)
    local held = if from == nil then of.heard else marks (of, from)

    of.ctx.last = held[id]
    held[id] = now
end

-- One payload or one entry, decoded under containment, and the byte past it.
function Boundary.ran (
    of: Boundary,
    def: Compile.Def,
    names: Names,
    take: (buffer, number, Types.ValidateContext) -> (number, any),
    b: buffer,
    pos: number
): (number?, any)
    local ok, at, value = pcall (take, b, pos, of.ctx)
    if ok then
        of.took = true
        return at, value
    end

    of.took = false

    local ends = resumed (at)
    if ends == nil then of.live = false end

    local about: Log.Facts = {
        definition = def.name,
        file = def.file,
        line = def.line,
        player = of.ctx.player,
    }

    diagnosed (at, names, about)
    Log.dropped (at, about, if of.ctx.player == nil then TRUSTED else HOSTILE)
    Tally.dropped (of.tally, def.name)

    return ends, nil
end

-- A failure about the frame rather than about anything in it, which closes it.
function Boundary.lost (of: Boundary, code: Catalog.Code, facts: Log.Facts)
    of.live = false

    local raised = { code = code, facts = facts }
    Log.dropped (
        raised,
        { player = of.ctx.player },
        if of.ctx.player == nil then TRUSTED else HOSTILE
    )

    --[[
        Against the namespace and no definition, which is what a count with no name to charge is
        for. What went wrong here is exactly which definition the frame said it was.
    ]]
    Tally.dropped (of.tally, nil)
end

-- A sender gone, and the stamps that were only ever about them.
function Boundary.left (of: Boundary, who: Player) of.stamps[who] = nil end

return table.freeze (Boundary)
