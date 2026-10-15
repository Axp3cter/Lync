--!strict
--!optimize 2
-- A set with a client on the other end: who may change it, what a change costs, and when a
-- watcher starts watching.

local Codecs = require("@src/codec")
local Set = require("@src/api/Set")
local Types = require("@src/Types")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Replica = require("@test/harness/Replica")

local SPACE = "records"

-- The one client, because every claim here is about a view rather than an audience.
local SENDER = "alice"

local ROSTER = "roster"

-- Three fields, and the third is marked. A marker is the one declaration a field carries that
-- changes how it travels, so the pair either side of it is what a marked field is read against.
local HP = "hp"
local POS = "pos"
local AIM = "aim"

-- The one record every check writes to, the negative id Studio hands a test player, and a second
-- ordinary one beside it.
local ID = 1
local NEGATIVE = -2
local OTHER = 2

-- Ids nothing like the slots they land in.
local FAR = 500
local APART = 40

-- The names of a record wide enough that a delta names its fields as a mask rather than a list.
local WIDE = table.freeze({ "a", "b", "c", "d", "e" })

-- Every composite a set may replicate, as the field each one is under, and the names they are
-- built over.
local HELD = "held"
local ROW = "row"
local LIST = "items"
local PURSE = "purse"
local FLAGS = "flags"
local EVENT = "event"
local MARKS = table.freeze({ "one", "two" })

-- What a field is set to, named for the part it plays. `LOST` is the value of an update the lane
-- is told to drop and `KEPT` the one it is told to carry, so a client landing on `KEPT` after
-- missing `LOST` was sent a value rather than a difference.
local START = 10
local HIGH = 90
local LOW = 20
local LOST = 30
local KEPT = 40
local PASSED = 50
local WON = 60

-- The pattern the lossy check hands the lane, and the one band it opens.
local ALTERNATING = table.freeze({ Doubles.FAULTED, Doubles.CLEAN })
local HALF = 0.5

type Seen = Replica.Seen
type Run = Replica.Run

-- Private -------------------------------------------------------------

local function health(): Types.Codec<number>
    return Codecs.int(0, 100)
end

local function small(): Types.Codec<number>
    return Codecs.int(0, 15)
end

-- The definitions one machine requires, built once per side.
local function defined(): any
    local codec = Codecs.struct({ [HP] = health(), [POS] = health(), [AIM] = health():newest() })
    return { [ROSTER] = Set.new(codec) }
end

-- The same record with both of its moving fields on the lossy lane, which is where two streams
-- can name the same records in one flush.
local function twinned(): any
    local codec = Codecs.struct({
        [HP] = health(),
        [POS] = health():newest(),
        [AIM] = health():newest(),
    })
    return { [ROSTER] = Set.new(codec) }
end

local function widened(): any
    local fields = {}
    for _, name in WIDE do
        fields[name] = health()
    end
    return { [ROSTER] = Set.new(Codecs.struct(fields)) }
end

-- A record of every composite the vocabulary builds.
local function composites(): any
    local codec = Codecs.struct({
        [ROW] = Codecs.struct({ [MARKS[1]] = small(), [MARKS[2]] = small() }),
        [LIST] = Codecs.array(small(), 0, 4),
        [PURSE] = Codecs.map(Codecs.enum(MARKS), small(), 0, 2),
        [FLAGS] = Codecs.bitfield(MARKS),
        [EVENT] = Codecs.tagged("kind", {
            [MARKS[1]] = Codecs.struct({ [ROW] = small() }),
            [MARKS[2]] = Codecs.struct({ [LIST] = small() }),
        }),
    })
    return { [HELD] = Set.new(codec) }
end

-- A record, fresh each time, because a set holds what it is handed.
local function record(): any
    return { [HP] = START, [POS] = START, [AIM] = START }
end

local function wide(to: number): any
    local of = {}
    for _, name in WIDE do
        of[name] = to
    end
    return of
end

local function composed(): any
    return {
        [ROW] = { [MARKS[1]] = 1, [MARKS[2]] = 2 },
        [LIST] = { 3, 4 },
        [PURSE] = { [MARKS[1]] = 5 },
        [FLAGS] = { [MARKS[1]] = true, [MARKS[2]] = false },
        [EVENT] = { kind = MARKS[1], [ROW] = 6 },
    }
end

-- Two machines on one lane over `defs`, the client watching `name` before it starts.
local function opened(defs: () -> any, name: string, chance: Doubles.Faults?, draw: (() -> number)?)
    local opening = { space = SPACE, defined = defs, watched = name, chance = chance, draw = draw }
    return Replica.open(opening, SENDER)
end

local function plain(): Run
    return opened(defined, ROSTER)
end

-- What the client holds for a record, which is the view every check reads.
local function holds(of: Run, id: number): any
    return of.client.defs[ROSTER]:get(id)
end

-- What one flush of `run` put on the wire.
local function cost(of: Run, run: () -> ()): number
    local before = Replica.carried(of)
    run()
    Replica.ships(of)
    return Replica.carried(of) - before
end

-- Public --------------------------------------------------------------

return {
    -- A client trying to change a set, which it may not: the server owns every record.
    Harness.case("set.server-owns", function()
        local of = plain()
        of.server.defs[ROSTER]:add(ID, record())
        Replica.ships(of)

        local theirs = of.client.defs[ROSTER]
        Expect.equal(#theirs, 1)
        local mine = "call, and this is a client"
        Expect.throws(function()
            theirs:add(OTHER, record())
        end, mine)
        Expect.throws(function()
            theirs:update(ID, { [HP] = HIGH })
        end, mine)
        Expect.throws(function()
            theirs:remove(ID)
        end, mine)
        Expect.throws(function()
            theirs:clear()
        end, mine)
        Expect.equal(#theirs, 1)
    end),

    -- Studio hands a test player a negative UserId, and an id crosses as a signed varint.
    Harness.case("set.negative-id-replicates", function()
        local of = plain()
        of.server.defs[ROSTER]:add(NEGATIVE, record())
        Replica.ships(of)

        Expect.equal(#of.client.defs[ROSTER], 1)
        local held = holds(of, NEGATIVE)
        Expect.holds(held ~= nil, `no record reached a client under {NEGATIVE}`)
        Expect.equal(held[HP], START)
    end),

    -- An update, and what it costs.
    Harness.case("set.update", function()
        local of = plain()
        local ours = of.server.defs[ROSTER]
        ours:add(ID, record())
        Replica.ships(of)

        local one = cost(of, function()
            ours:update(ID, { [HP] = HIGH })
        end)
        local two = cost(of, function()
            ours:update(ID, { [HP] = LOW, [POS] = HIGH })
        end)
        Expect.holds(one > 0, "an update carried nothing")
        Expect.holds(one < two, `one field cost {one} and two cost {two}`)

        local mine = holds(of, ID)
        Expect.equal(mine[HP], LOW)
        Expect.equal(mine[POS], HIGH)
    end),

    -- A watcher attached after the set has already been told things.
    Harness.case("life.set-callbacks-anytime", function()
        local of = plain()
        local ours = of.server.defs[ROSTER]
        ours:add(ID, record())
        Replica.ships(of)
        Expect.equal(#of.seen, 1)

        local late: { Seen } = {}
        Replica.watch(of.client.defs[ROSTER], late)
        Expect.equal(#late, 0)

        ours:update(ID, { [HP] = HIGH })
        Replica.ships(of)
        Expect.equal(#of.seen, 2)
        Expect.equal(#late, 1)
        Expect.equal(late[1].kind, "changed")
        Expect.equal(late[1].record[HP], HIGH)
    end),

    -- A field a caller marked `:newest()`: a lost value is never resent as a difference, the next
    -- value lands whole, and two writes in one flush cost what one does.
    Harness.case("set.newest-field", function()
        local faults = { lose = HALF, double = 0, hold = 0 }
        local lossy = opened(defined, ROSTER, faults, Doubles.scripted(ALTERNATING))
        local ours = lossy.server.defs[ROSTER]
        ours:add(ID, record())
        Replica.ships(lossy)
        Expect.equal(holds(lossy, ID)[AIM], START)

        ours:update(ID, { [AIM] = LOST, [HP] = HIGH })
        Replica.ships(lossy)
        Expect.holds(lossy.wire:moved().lost > 0, "the lane was asked to lose and lost nothing")
        Expect.equal(holds(lossy, ID)[AIM], START)
        Expect.equal(holds(lossy, ID)[HP], HIGH)

        ours:update(ID, { [AIM] = KEPT })
        Replica.ships(lossy)
        Expect.equal(holds(lossy, ID)[AIM], KEPT)

        local quiet = plain()
        local theirs = quiet.server.defs[ROSTER]
        theirs:add(ID, record())
        Replica.ships(quiet)
        local once = cost(quiet, function()
            theirs:update(ID, { [AIM] = PASSED })
        end)
        local twice = cost(quiet, function()
            theirs:update(ID, { [AIM] = PASSED })
            theirs:update(ID, { [AIM] = WON })
        end)
        Expect.equal(twice, once)
        Expect.equal(holds(quiet, ID)[AIM], WON)
    end),

    -- A record written again with a value equal to the one it holds, where every field is a
    -- table: a fresh composite of the same content is no change.
    Harness.case("set.changed-quiet-composite", function()
        local of = opened(composites, HELD)
        local set = of.server.defs[HELD]
        set:add(ID, composed())
        Replica.ships(of)
        Expect.equal(#of.seen, 1)

        local before = of.wire:moved().frames
        for _, name in { ROW, LIST, PURSE, FLAGS, EVENT } do
            set:update(ID, { [name] = composed()[name] })
            Replica.ships(of)
        end
        set:update(ID, composed())
        Replica.ships(of)
        Expect.equal(of.wire:moved().frames, before)
        Expect.equal(#of.seen, 1)

        -- And a real change still crosses, so the silence above is not the lane being shut.
        local moved = composed()
        moved[LIST] = { 7, 8, 9 }
        set:update(ID, moved)
        Replica.ships(of)
        Expect.equal(#of.seen, 2)
    end),

    -- Two deltas over one record, the second naming fewer fields, which is the shape that reads a
    -- selection past its own end.
    Harness.case("set.delta-fieldset", function()
        local of = opened(widened, ROSTER)
        local set = of.server.defs[ROSTER]
        set:add(ID, wide(START))
        Replica.ships(of)
        set:update(ID, { a = HIGH, b = HIGH, e = HIGH })
        Replica.ships(of)
        set:update(ID, { a = LOW, c = LOW })
        Replica.ships(of)

        local mine = set:get(ID)
        local yours = holds(of, ID)
        Expect.holds(yours ~= nil, "a record the server holds did not reach the client at all")
        for _, name in WIDE do
            Expect.equal(yours[name], mine[name])
        end

        -- And the three flushes are three tellings, so a section the reader threw away shows.
        Expect.equal(#of.seen, 3)
        Expect.equal(of.seen[1].kind, "added")
        Expect.equal(of.seen[2].kind, "changed")
        Expect.equal(of.seen[3].kind, "changed")
    end),

    -- Two streams that moved over the same records in one flush, and a viewer owing both fields.
    Harness.case("set.two-streams-together", function()
        local of = opened(twinned, ROSTER)
        local ours = of.server.defs[ROSTER]
        ours:add(ID, record())
        Replica.ships(of)
        ours:update(ID, { [POS] = HIGH, [AIM] = WON })
        Replica.ships(of)

        local one = holds(of, ID)
        Expect.equal(one[POS], HIGH)
        Expect.equal(one[AIM], WON)
    end),

    -- The same two streams where each moved over a record the other did not, and nothing shared.
    Harness.case("set.two-streams-apart", function()
        local of = opened(twinned, ROSTER)
        local ours = of.server.defs[ROSTER]
        ours:add(ID, record())
        ours:add(OTHER, record())
        Replica.ships(of)
        ours:update(ID, { [POS] = HIGH })
        ours:update(OTHER, { [AIM] = WON })
        Replica.ships(of)

        local one, two = holds(of, ID), holds(of, OTHER)
        Expect.equal(one[POS], HIGH)
        Expect.equal(one[AIM], START)
        Expect.equal(two[POS], START)
        Expect.equal(two[AIM], WON)
    end),

    -- Records whose ids are nothing like the slots they land in: a store keeps a column by slot
    -- and a record by id, and the two agree in any check that adds one record at a time.
    Harness.case("set.ids-are-not-slots", function()
        local of = plain()
        local ours = of.server.defs[ROSTER]
        local ids = { FAR, FAR + APART, FAR + APART * 2 }
        for _, id in ids do
            ours:add(id, record())
        end
        Replica.ships(of)
        for index, id in ids do
            ours:update(id, { [AIM] = index, [HP] = HIGH })
        end
        Replica.ships(of)

        for index, id in ids do
            local one = holds(of, id)
            Expect.holds(one ~= nil, `nothing came back for {id}`)
            Expect.equal(one[AIM], index)
            Expect.equal(one[HP], HIGH)
        end
    end),
}
