--!strict
--!optimize 2
-- A set under load: what it costs to hold records, to change many at once, and to move a viewer
-- from seeing one partition to seeing another.

local Session = require("@src/runtime/Session")
local Set = require("@src/api/Set")

local Doubles = require("@fixtures/Doubles")
local Schemas = require("@fixtures/Schemas")

local Harness = require("@bench/harness")

local SPACE = "replication"

-- The set, the field it partitions by, and the one viewer every row here has.
local BOARD = "board"
local TEAM = "team"
local WATCHER = "alice"

-- The two partitions, which the widest fixture's own enum names.
local RED = "red"
local BLUE = "blue"

-- Records the set holds, and how many of them one burst dirties.
local HELD = 64
local DIRTIED = 16

-- The record every row starts from, and the field a burst writes.
local CARRIED = "typical"
local ONE = "count"
local LOW = 100
local HIGH = 900

-- Both machines, since a replication row is measured on the sending side and read on the other.
-- `up` is the toggle a row steps between turns, so a write is always a write.
type Run = {
    read wire: Doubles.Wire,
    read server: Session.Session,
    read set: any,
    read who: Player,
    up: boolean,
}

-- Private -------------------------------------------------------------

-- Keyed, because one row moves a viewer between partitions.
local function defined(): any
    return { [BOARD] = Set.new(Schemas.everything.codec):keyBy(TEAM) }
end

-- A record on one of the two partitions, cloned from the fixture case.
local function record(id: number): any
    local of = table.clone(Schemas.cased(Schemas.everything, CARRIED))
    of[TEAM] = if id % 2 == 0 then RED else BLUE
    return of
end

-- A server, one viewer, and a set already holding its records and already carried to the client.
local function opened(): Run
    local wire = Doubles.wire()
    local roster = Doubles.roster()
    local serverDefs = defined()
    local server = Session.new(SPACE, serverDefs, wire:server(), roster, "server")
    server:start()

    local who = roster:join(WATCHER)
    Session.new(SPACE, defined(), wire:client(who), roster, "client"):start()
    wire:settle()

    local set = serverDefs[BOARD]
    set:audience(RED, { who })
    set:audience(BLUE, { who })
    for id = 1, HELD do
        set:add(id, record(id))
    end
    local of: Run = { wire = wire, server = server, set = set, who = who, up = false }
    Harness.quiet(of)
    return of
end

-- A fraction of the set dirtied at once, which is what a busy frame looks like.
local function stormed(of: Run): number
    local value = Harness.stepped(of, LOW, HIGH)
    for id = 1, DIRTIED do
        of.set:update(id, { [ONE] = value })
    end
    return Harness.drained(of)
end

-- The viewer moved from seeing one partition to seeing the other.
local function moved(of: Run): number
    of.up = not of.up
    of.set:audience(if of.up then RED else BLUE, { of.who })
    of.set:audience(if of.up then BLUE else RED, {})
    return Harness.drained(of)
end

-- Public --------------------------------------------------------------

return {
    -- A set holding sixty-four records with nothing changed, flushed.
    Harness.row({ name = "replication.steady", setup = opened, run = Harness.drained }),

    -- A quarter of the set dirtied in one frame.
    Harness.row({
        name = "replication.storm",
        setup = opened,
        run = stormed,
        bytes = Harness.weighs(stormed),
    }),

    -- A viewer's visibility moved from one partition to the other.
    Harness.row({
        name = "replication.catchup",
        setup = opened,
        run = moved,
        bytes = Harness.weighs(moved),
    }),
}
