--!strict
--!optimize 2
-- What a set costs between two flushes: the fold, the walk, the send, and every way of costing
-- nothing.

local Session = require("@src/runtime/Session")
local Set = require("@src/api/Set")

local Doubles = require("@fixtures/Doubles")
local Schemas = require("@fixtures/Schemas")

local Harness = require("@bench/harness")

local SPACE = "deltas"

-- The one record every row mutates, and the definition holding it.
local BOARD = "board"
local ID = 1

-- The viewers, because one row is the same flush reaching two of them.
local ALONE = "alice"
local BESIDE = "bob"

-- The record every row starts from.
local CARRIED = "typical"

-- The field one flush dirties, and the two values it alternates between.
local ONE = "count"
local LOW = 100
local HIGH = 900

-- The composite field a set carries, and the two names inside it.
local NESTED = "nested"
local NEAR = "near"
local FAR = "far"

-- Mutations the fold row makes between two flushes.
local FOLDED = 8

-- One server and the set every row here writes to, built once per row and reused every turn.
-- `one` is the table a single field write is handed, and `pair` two tables holding one content,
-- handed over in turn.
type Run = {
    read wire: Doubles.Wire,
    read server: Session.Session,
    read set: any,
    read record: any,
    read fields: { string },
    read one: { [string]: any },
    read pair: { { [string]: any } },
    turned: boolean,
    up: boolean,
}

-- Private -------------------------------------------------------------

-- Unkeyed, so every client sees every record and the state sections are the shared ones.
local function defined(): any
    return { [BOARD] = Set.new(Schemas.everything.codec) }
end

-- Every field the mask row writes, which is every one the typical case fills.
local function fielded(record: any): { string }
    local out = {}
    for name in record do
        table.insert(out, name)
    end
    table.sort(out)
    return out
end

-- A server, a set with one record in it, and as many viewers as the row wants.
local function opened(viewers: number): Run
    local wire = Doubles.wire()
    local roster = Doubles.roster()
    local serverDefs = defined()
    local server = Session.new(SPACE, serverDefs, wire:server(), roster, "server")
    server:start()
    for index = 1, viewers do
        local who = roster:join(if index == 1 then ALONE else BESIDE)
        Session.new(SPACE, defined(), wire:client(who), roster, "client"):start()
    end
    wire:settle()

    local record = Schemas.cased(Schemas.everything, CARRIED)
    local set = serverDefs[BOARD]
    set:add(ID, record)
    local of: Run = {
        wire = wire,
        server = server,
        set = set,
        record = record,
        fields = fielded(record),
        one = {},
        pair = {
            { [NEAR] = record[NESTED][NEAR], [FAR] = record[NESTED][FAR] },
            { [NEAR] = record[NESTED][NEAR], [FAR] = record[NESTED][FAR] },
        },
        turned = false,
        up = false,
    }
    Harness.quiet(of)
    return of
end

-- One field dirtied and the flush that carries it, which is the shape of most state traffic.
local function nudged(of: Run): number
    of.set:update(ID, { [ONE] = Harness.stepped(of, LOW, HIGH) })
    return Harness.drained(of)
end

-- The same field written many times before one flush, which is the fold.
local function folded(of: Run): number
    for _ = 1, FOLDED do
        of.set:update(ID, { [ONE] = Harness.stepped(of, LOW, HIGH) })
    end
    return Harness.drained(of)
end

-- Every field the record fills, dirtied at once.
local function widened(of: Run): number
    local fields = {}
    for _, name in of.fields do
        fields[name] = of.record[name]
    end
    fields[ONE] = Harness.stepped(of, LOW, HIGH)
    of.set:update(ID, fields)
    return Harness.drained(of)
end

-- The composite field written with a table holding what it already holds.
local function copied(of: Run): number
    of.turned = not of.turned
    of.one[NESTED] = of.pair[if of.turned then 1 else 2]
    of.set:update(ID, of.one)
    of.one[NESTED] = nil
    return Harness.drained(of)
end

-- The field written with the value it already holds, which is the write that should not ship.
local function echoed(of: Run): number
    of.one[ONE] = of.record[ONE]
    of.set:update(ID, of.one)
    return Harness.drained(of)
end

local function alone(): Run
    return opened(1)
end

-- Public --------------------------------------------------------------

return {
    -- One field changed, and the flush that carries it to one viewer.
    Harness.row({
        name = "deltas.plan",
        setup = alone,
        run = nudged,
        bytes = Harness.weighs(nudged),
    }),

    -- The same turn with a second viewer on the lane.
    Harness.row({
        name = "deltas.apply",
        setup = function(): Run
            return opened(2)
        end,
        run = nudged,
        bytes = Harness.weighs(nudged),
    }),

    -- Many writes to one field, and the one section they come to.
    Harness.row({
        name = "deltas.coalesce",
        setup = alone,
        run = folded,
        bytes = Harness.weighs(folded),
    }),

    -- Every field of the widest record dirty at once.
    Harness.row({ name = "deltas.mask-walk", setup = alone, run = widened }),

    -- A write of the table a record's composite field already holds.
    Harness.row({
        name = "deltas.echoed-table",
        setup = alone,
        run = copied,
        bytes = Harness.weighs(copied),
    }),

    -- A write of the value a record already holds.
    Harness.row({
        name = "deltas.suppressed",
        setup = alone,
        run = echoed,
        bytes = Harness.weighs(echoed),
    }),

    -- A flush over a set with a marked field in it and nothing changed.
    Harness.row({ name = "deltas.idle", setup = alone, run = Harness.drained }),
}
