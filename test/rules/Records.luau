--!strict
--!optimize 2
--[[
    A set with a client on the other end: who may change it, what a change costs, and when a watcher
    starts watching.
]]

local Lync = require ("@src")

local Doubles = require ("@fixtures/Doubles")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Replica = require ("@test/harness/Replica")

-- Constants -----------------------------------------------------------

const SPACE = "records"

-- The one client, because every claim here is about a view rather than an audience.
const SENDER = "alice"

const ROSTER = "roster"

--[[
    Three fields, and the third is marked. A marker is the one declaration a field carries that
    changes how it travels, so the record holds one of each and the pair either side of it is what a
    marked field is read against.
]]
const HP = "hp"
const POS = "pos"
const AIM = "aim"

-- One record, and the two ids the checks that need a second one use.
const ID = 1

-- What Studio hands a test player, which a set is expected to carry unchanged.
const NEGATIVE = -2
const OTHER = 2

--[[
    The names of a record wide enough that a delta names its fields as a mask rather than as a list,
    which is what `set.delta-fieldset` is about and is five.
]]
const WIDE = table.freeze ({ "a", "b", "c", "d", "e" })

--[[
    Every composite a set may replicate, as the field each one is under.

    One kind would be a reading about that kind. What is asked is that the promise holds wherever a
    value is a table, and these are the tables the vocabulary builds.
]]
const HELD = "held"
const ROW = "row"
const LIST = "items"
const PURSE = "purse"
const FLAGS = "flags"
const EVENT = "event"

-- The names a composite is built over, kept short because what they are does not matter.
const MARKS = table.freeze ({ "one", "two" })

--[[
    What a field is set to, named for the part it plays. `LOST` is the value of an update the lane
    is told to drop, and `KEPT` the one it is told to carry, so a client landing on `KEPT` after
    missing `LOST` is a client that was sent a value rather than a difference.
]]
const START = 10
const HIGH = 90
const LOW = 20
const LOST = 30
const KEPT = 40
const PASSED = 50
const WON = 60

-- The two ends of a draw, bound short, and the pattern the lossy check hands the lane.
const FAULTED = Doubles.FAULTED
const CLEAN = Doubles.CLEAN
const ALTERNATING = table.freeze ({ FAULTED, CLEAN })

-- The one band the lossy check opens.
const HALF = 0.5

-- Types ---------------------------------------------------------------

type Seen = Replica.Seen
type Run = Replica.Run

-- Private -------------------------------------------------------------

-- The definitions one machine requires, built once per side.
local function defined (): any
    return {
        [ROSTER] = Lync.replicate (Lync.struct ({
            [HP] = Lync.int (0, 100),
            [POS] = Lync.int (0, 100),
            [AIM] = Lync.int (0, 100):newest (),
        })),
    }
end

-- A record, fresh each time, because a set holds what it is handed.
local function record (): any return { [HP] = START, [POS] = START, [AIM] = START } end

--[[
    The same record with both of its moving fields on the lossy lane, which is where two streams
    can name the same records in one flush and spell them once between them.
]]
local function twinned (): any
    return {
        [ROSTER] = Lync.replicate (Lync.struct ({
            [HP] = Lync.int (0, 100),
            [POS] = Lync.int (0, 100):newest (),
            [AIM] = Lync.int (0, 100):newest (),
        })),
    }
end

-- The wide record's definitions, and one of its records, both built the way the narrow one is.
local function widened (): any
    local fields = {}
    for _, name in WIDE do
        fields[name] = Lync.int (0, 100)
    end
    return { [ROSTER] = Lync.replicate (Lync.struct (fields)) }
end

local function wide (to: number): any
    local of = {}
    for _, name in WIDE do
        of[name] = to
    end
    return of
end

-- A record of every composite the vocabulary builds, and one value of it.
local function composites (): any
    return {
        [HELD] = Lync.replicate (Lync.struct ({
            [ROW] = Lync.struct ({ [MARKS[1]] = Lync.int (0, 15), [MARKS[2]] = Lync.int (0, 15) }),
            [LIST] = Lync.array (Lync.int (0, 15), 0, 4),
            [PURSE] = Lync.map (Lync.enum (MARKS), Lync.int (0, 15), 0, 2),
            [FLAGS] = Lync.bitfield (MARKS),
            [EVENT] = Lync.tagged ("kind", {
                [MARKS[1]] = Lync.struct ({ [ROW] = Lync.int (0, 15) }),
                [MARKS[2]] = Lync.struct ({ [LIST] = Lync.int (0, 15) }),
            }),
        })),
    }
end

local function composed (): any
    return {
        [ROW] = { [MARKS[1]] = 1, [MARKS[2]] = 2 },
        [LIST] = { 3, 4 },
        [PURSE] = { [MARKS[1]] = 5 },
        [FLAGS] = { [MARKS[1]] = true, [MARKS[2]] = false },
        [EVENT] = { kind = MARKS[1], [ROW] = 6 },
    }
end

local watching = Replica.watch
local ships = Replica.ships
local carried = Replica.carried

--[[
    Two machines on one lane, the client watching before it starts, because that is where a caller
    writes a watcher. One check attaches a second afterwards and that is its subject.
]]
local function opened (chance: Doubles.Faults?, draw: (() -> number)?): Run
    local opening = {
        space = SPACE,
        defined = defined,
        watched = ROSTER,
        chance = chance,
        draw = draw,
    }
    return Replica.open (opening, SENDER)
end

-- The same two machines over the record whose two moving fields both stream.
local function twins (): Run
    return Replica.open ({ space = SPACE, defined = twinned, watched = ROSTER }, SENDER)
end

-- What the client holds for the one record, which is the view every check reads.
local function held (of: Run): any return of.client.defs[ROSTER]:get (ID) end

-- The same, for whichever record a check about two streams is asking after.
local function holds (of: Run, id: number): any return of.client.defs[ROSTER]:get (id) end

-- Public --------------------------------------------------------------

return {
    --[[
        A client trying to change a set, which it may not. The server owns every record and a client
        holds a view of what its audiences allow, so a client that could write would make every
        field a value the server had to re-check.
    ]]
    Harness.case ("set.server-owns", function ()
        local of = opened ()

        of.server.defs[ROSTER]:add (ID, record ())
        ships (of)

        local theirs = of.client.defs[ROSTER]
        Expect.equal (#theirs, 1)

        local mine = "call, and this is a client"
        Expect.throws (function () theirs:add (OTHER, record ()) end, mine)
        Expect.throws (function () theirs:update (ID, { [HP] = HIGH }) end, mine)
        Expect.throws (function () theirs:remove (ID) end, mine)
        Expect.throws (function () theirs:clear () end, mine)

        Expect.equal (#theirs, 1)
    end),

    --[[
        Studio hands a test player a negative UserId. An id encodes unsigned, so a set holding one
        proves nothing about a set sending one.
    ]]
    Harness.case ("set.negative-id-replicates", function ()
        local of = opened ()

        of.server.defs[ROSTER]:add (NEGATIVE, record ())
        ships (of)

        local theirs = of.client.defs[ROSTER]
        Expect.equal (#theirs, 1)

        local held = theirs:get (NEGATIVE)
        Expect.holds (held ~= nil, `no record reached a client under {NEGATIVE}`)
        Expect.equal ((held :: any)[HP], record ()[HP])
    end),

    -- An update, and what it costs.
    Harness.case ("set.update", function ()
        local of = opened ()
        local ours = of.server.defs[ROSTER]

        ours:add (ID, record ())
        ships (of)

        local before = carried (of)
        ours:update (ID, { [HP] = HIGH })
        ships (of)
        local one = carried (of) - before

        before = carried (of)
        ours:update (ID, { [HP] = LOW, [POS] = HIGH })
        ships (of)
        local two = carried (of) - before

        Expect.holds (one > 0, "an update carried nothing")
        Expect.holds (one < two, `one field cost {one} and two cost {two}`)

        local mine = held (of)
        Expect.equal (mine[HP], LOW)
        Expect.equal (mine[POS], HIGH)
    end),

    -- A watcher attached after the set has already been told things.
    Harness.case ("life.set-callbacks-anytime", function ()
        local of = opened ()
        local ours = of.server.defs[ROSTER]

        ours:add (ID, record ())
        ships (of)
        Expect.equal (#of.seen, 1)

        local late: { Seen } = {}
        watching (of.client.defs[ROSTER], late)
        Expect.equal (#late, 0)

        ours:update (ID, { [HP] = HIGH })
        ships (of)

        Expect.equal (#of.seen, 2)
        Expect.equal (#late, 1)
        Expect.equal (late[1].kind, "changed")
        Expect.equal (late[1].record[HP], HIGH)
    end),

    -- A field a caller marked `:newest()`, and the three things that makes true.
    Harness.case ("set.newest-field", function ()
        local lossy = opened ({ lose = HALF, double = 0, hold = 0 }, Doubles.scripted (ALTERNATING))
        local ours = lossy.server.defs[ROSTER]

        ours:add (ID, record ())
        ships (lossy)
        Expect.equal (held (lossy)[AIM], START)

        ours:update (ID, { [AIM] = LOST, [HP] = HIGH })
        ships (lossy)

        Expect.holds (lossy.wire:moved ().lost > 0, "the lane was asked to lose and lost nothing")
        Expect.equal (held (lossy)[AIM], START)
        Expect.equal (held (lossy)[HP], HIGH)

        ours:update (ID, { [AIM] = KEPT })
        ships (lossy)
        Expect.equal (held (lossy)[AIM], KEPT)

        local quiet = opened ()
        local theirs = quiet.server.defs[ROSTER]

        theirs:add (ID, record ())
        ships (quiet)

        local before = carried (quiet)
        theirs:update (ID, { [AIM] = PASSED })
        ships (quiet)
        local once = carried (quiet) - before

        before = carried (quiet)
        theirs:update (ID, { [AIM] = PASSED })
        theirs:update (ID, { [AIM] = WON })
        ships (quiet)
        local twice = carried (quiet) - before

        Expect.equal (twice, once)
        Expect.equal (held (quiet)[AIM], WON)
    end),

    --[[
        A record written again with a value equal to the one it holds, where every field is a table.
        Comparison is identity for a table, so a caller who builds their composite rather than
        keeping it wrote a change every time however little moved.
    ]]
    Harness.case ("set.changed-quiet-composite", function ()
        local of = Replica.open ({ space = SPACE, defined = composites, watched = HELD }, SENDER)
        local seen = of.seen

        local set = of.server.defs[HELD]
        set:add (ID, composed ())
        ships (of)

        Expect.equal (#seen, 1)

        -- A fresh value of the same content, once per field and then all of them at once.
        local before = of.wire:moved ().frames
        for _, name in { ROW, LIST, PURSE, FLAGS, EVENT } do
            set:update (ID, { [name] = composed ()[name] })
            ships (of)
        end

        set:update (ID, composed ())
        ships (of)

        Expect.equal (of.wire:moved ().frames, before)
        Expect.equal (#seen, 1)

        -- And a real change still crosses, so the silence above is not the lane being shut.
        local moved = composed ()
        moved[LIST] = { 7, 8, 9 }

        set:update (ID, moved)
        ships (of)

        Expect.equal (#seen, 2)
    end),

    --[[
        Two deltas over one record, the second naming fewer fields, which is the shape that reads a
        selection past its own end. A walk past the count read whatever the section before it left
        there, set a bit for a field the delta does not carry, and took every field after it at the
        wrong offset.
    ]]
    Harness.case ("set.delta-fieldset", function ()
        local of = Replica.open ({ space = SPACE, defined = widened, watched = ROSTER }, SENDER)
        local seen = of.seen

        local set = of.server.defs[ROSTER]
        set:add (ID, wide (START))
        ships (of)

        set:update (ID, { a = HIGH, b = HIGH, e = HIGH })
        ships (of)

        set:update (ID, { a = LOW, c = LOW })
        ships (of)

        local mine = set:get (ID)
        local yours = of.client.defs[ROSTER]:get (ID)
        Expect.holds (yours ~= nil, "a record the server holds did not reach the client at all")

        for _, name in WIDE do
            Expect.equal ((yours :: any)[name], (mine :: any)[name])
        end

        --[[
            And the three flushes are three tellings. A section the reader threw away is a section
            that reported nothing, so a client left holding the right record because nothing arrived
            would pass the reading above and fail this one.
        ]]
        Expect.equal (#seen, 3)
        Expect.equal (seen[1].kind, "added")
        Expect.equal (seen[2].kind, "changed")
        Expect.equal (seen[3].kind, "changed")
    end),
    --[[
        Two streams that moved over the same records in one flush. The slots they name are one run
        and the generations one run, so what tells the two apart on the wire is the pair of numbers
        naming each stream and the column of values behind it, and a viewer owes both fields.
    ]]
    Harness.case ("set.two-streams-together", function ()
        local of = twins ()
        local ours = of.server.defs[ROSTER]

        ours:add (ID, record ())
        ships (of)

        ours:update (ID, { [POS] = HIGH, [AIM] = WON })
        ships (of)

        local one = held (of)
        Expect.equal (one[POS], HIGH)
        Expect.equal (one[AIM], WON)
    end),

    --[[
        The same two streams where each moved over a record the other did not. Nothing is shared
        then, and a lane that shared anyway would hand one record the other's value: the run a
        section spells has to be the run its every column was gathered against.
    ]]
    Harness.case ("set.two-streams-apart", function ()
        local of = twins ()
        local ours = of.server.defs[ROSTER]

        ours:add (ID, record ())
        ours:add (OTHER, record ())
        ships (of)

        ours:update (ID, { [POS] = HIGH })
        ours:update (OTHER, { [AIM] = WON })
        ships (of)

        local one, two = holds (of, ID), holds (of, OTHER)
        Expect.equal (one[POS], HIGH)
        Expect.equal (one[AIM], START)
        Expect.equal (two[POS], START)
        Expect.equal (two[AIM], WON)
    end),
    --[[
        Records whose ids are nothing like the slots they land in. A store keeps a column by slot
        and a record by id, and the two agree in any check that adds one record at a time, so a
        write that reached for the wrong one of them would look right everywhere but here.
    ]]
    Harness.case ("set.ids-are-not-slots", function ()
        const FAR = 500
        const APART = 40

        local of = opened ()
        local ours = of.server.defs[ROSTER]

        -- Three ids far apart, which land in the three slots a partition hands out in order.
        local ids = { FAR, FAR + APART, FAR + APART * 2 }
        for _, id in ids do
            ours:add (id, record ())
        end
        ships (of)

        for index, id in ids do
            ours:update (id, { [AIM] = index, [HP] = HIGH })
        end
        ships (of)

        for index, id in ids do
            local one = of.client.defs[ROSTER]:get (id)
            Expect.holds (one ~= nil, `nothing came back for {id}`)
            Expect.equal (one[AIM], index)
            Expect.equal (one[HP], HIGH)
        end
    end),
}
