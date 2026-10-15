--!strict
--!optimize 2
-- What a viewer holds and what it was told, one promise at a time.

local Codecs = require("@src/codec")
local Set = require("@src/api/Set")
local Types = require("@src/Types")

local Doubles = require("@fixtures/Doubles")
local Schemas = require("@fixtures/Schemas")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Replica = require("@test/harness/Replica")

local SPACE = "views"

-- Two clients, because a claim about who holds a record needs somebody who does not.
local ALICE = "alice"
local BOB = "bob"

local ROSTER = Schemas.ROSTER

-- One unkeyed record: a number that changes and a second that stays, so a delta names one field.
local HP = Schemas.HP
local POS = "pos"

-- The keyed record's partition field and the two keys a check grants.
local TEAM = Schemas.TEAM
local RED = Schemas.RED
local BLUE = Schemas.BLUE

-- The ids a check names, and the values it moves them between.
local ID = 1
local OTHER = 2
local THIRD = 3

local START = 10
local HIGH = 90
local LOW = 20

local REMOVED: Types.Cause = "removed"
local CLEARED: Types.Cause = "cleared"

-- A lane that hands every frame over twice, which is the one thing an unordered lane does that
-- nothing else here asks for.
local DOUBLING: Doubles.Faults = table.freeze({ lose = 0, double = 1, hold = 0 })
local EVERY_FRAME = table.freeze({ Doubles.FAULTED })

-- More records than one flush at the floor budget can carry.
local MANY = 200

-- A cap on how often a streamed field goes out, how many flushes a check drives past it, and the
-- most that run may put on the wire. A handful of flushes in a row is over inside one window, so
-- what a rate lets through is the first and room for a run that opened just as a window closed.
local RATE = 4
local RAPID = 5
local LETS = 2

-- Flushes enough to walk a partition of `MANY` end to end however few slots one section takes.
local DRAINS = 24

-- The wide field a record of `MANY` carries, and what fills it.
local NOTE = "note"
local WIDTH = 64
local FILLED = string.rep("x", WIDTH)

-- More than one round, which is the whole of what makes a late joiner behind rather than late.
local SEVERAL = 2
local LIMIT = Doubles.ROUNDS

-- A few records for a listener that comes apart on one of them.
local FEW = 4
local BREAKS = 2

type Seen = Replica.Seen
type Run = Replica.Run

-- Private -------------------------------------------------------------

local function health(): Types.Codec<number>
    return Codecs.int(0, 100)
end

-- An unkeyed set with two fields, so an update naming one of them is a delta and a check can tell
-- a keyframe from a difference.
local function defined(): any
    return { [ROSTER] = Set.new(Codecs.struct({ [HP] = health(), [POS] = health() })) }
end

-- A field that rides the lossy lane. `pos` rather than `hp`, so the field that streams is not the
-- field every other check here moves.
local function streamed(): any
    return { [ROSTER] = Set.new(Codecs.struct({ [HP] = health(), [POS] = health():newest() })) }
end

-- A streamed field under a cap on how often it may go out.
local function paced(): any
    local codec = Codecs.struct({ [HP] = health(), [POS] = health():newest(RATE) })
    return { [ROSTER] = Set.new(codec) }
end

-- A field wide enough to make a flush choose, which is what a catch-up needs.
local function heavy(): any
    local codec = Codecs.struct({ [HP] = health(), [NOTE] = Codecs.str(0, WIDTH) })
    return { [ROSTER] = Set.new(codec) }
end

local function laden(): any
    return { [HP] = START, [NOTE] = FILLED }
end

local function record(): any
    return { [HP] = START, [POS] = START }
end

local function teamed(side: string): any
    return { [TEAM] = side, [HP] = START }
end

local function opened(built: () -> any): Run
    return Replica.open({ space = SPACE, defined = built, watched = ROSTER }, ALICE)
end

-- Every telling, as the kinds in the order they arrived, which is what an order check compares.
local function kinds(seen: { Seen }): string
    local out = {}
    for _, one in seen do
        table.insert(out, one.kind)
    end
    return table.concat(out, " ")
end

-- Public --------------------------------------------------------------

return {
    -- A record added. The viewer is told once, with the id and the record, and after the flush
    -- rather than at the call.
    Harness.case("set.add", function()
        local of = opened(defined)
        Replica.ours(of):add(ID, record())
        Expect.equal(#of.seen, 0)

        Replica.ships(of)
        Expect.equal(#of.seen, 1)
        Expect.equal(of.seen[1].kind, "added")
        Expect.equal(of.seen[1].id, ID)
        Expect.equal(of.seen[1].record[HP], START)
        Expect.equal(of.seen[1].record[POS], START)
    end),

    -- A record removed, and the cause it carries.
    Harness.case("set.remove", function()
        local of = opened(defined)
        local set = Replica.ours(of)
        set:add(ID, record())
        Replica.ships(of)
        set:remove(ID)
        Replica.ships(of)

        Expect.equal(#of.seen, 2)
        Expect.equal(of.seen[2].kind, "removed")
        Expect.equal(of.seen[2].id, ID)
        Expect.equal(of.seen[2].cause, REMOVED)
        Expect.equal(of.viewers[1].set:get(ID), nil)
    end),

    -- A set emptied: every record the viewer held is a removal carrying the other cause.
    Harness.case("set.clear", function()
        local of = opened(defined)
        local set = Replica.ours(of)
        set:add(ID, record())
        set:add(OTHER, record())
        Replica.ships(of)
        set:clear()
        Replica.ships(of)

        Expect.equal(#of.seen, 4)
        local gone = {}
        for at = 3, 4 do
            Expect.equal(of.seen[at].kind, "removed")
            Expect.equal(of.seen[at].cause, CLEARED)
            gone[of.seen[at].id] = true
        end
        Expect.holds(gone[ID] and gone[OTHER], "a clear left a record behind")
        Expect.equal(#of.viewers[1].set, 0)
    end),

    -- What `#set` counts: a client's length is what it has been given, never what the server owns.
    Harness.case("set.len", function()
        local of = opened(defined)
        local set = Replica.ours(of)
        local view = of.viewers[1].set
        Expect.equal(#view, 0)

        set:add(ID, record())
        set:add(OTHER, record())
        Expect.equal(#set, 2)
        Expect.equal(#view, 0)

        Replica.ships(of)
        Expect.equal(#view, 2)

        set:remove(ID)
        Replica.ships(of)
        Expect.equal(#view, 1)
    end),

    -- Two updates to one field between flushes: the viewer is told once, the last value.
    Harness.case("set.changed-net", function()
        local of = opened(defined)
        local set = Replica.ours(of)
        set:add(ID, record())
        Replica.ships(of)
        set:update(ID, { [HP] = HIGH })
        set:update(ID, { [HP] = LOW })
        Replica.ships(of)

        Expect.equal(#of.seen, 2)
        Expect.equal(of.seen[2].kind, "changed")
        Expect.equal(of.seen[2].record[HP], LOW)
        Expect.equal(of.viewers[1].set:get(ID)[HP], LOW)
    end),

    -- A streamed field whose section the lane hands over twice. The ring a newest stream is
    -- ordered by tells the second copy from the first, so there is nothing in it left to apply.
    Harness.case("set.newest-doubled", function()
        local of = Replica.open({
            space = SPACE,
            defined = streamed,
            watched = ROSTER,
            chance = DOUBLING,
            draw = Doubles.scripted(EVERY_FRAME),
        }, ALICE)
        local set = Replica.ours(of)
        set:add(ID, record())
        Replica.ships(of)

        local before = #of.seen
        set:update(ID, { [POS] = HIGH })
        Replica.ships(of)

        Expect.holds(
            of.wire:moved().doubled > 0,
            "the lane was asked to double and doubled nothing"
        )
        Expect.equal(#of.seen - before, 1)
        Expect.equal(of.seen[#of.seen].kind, "changed")
        Expect.equal(of.seen[#of.seen].record[POS], HIGH)
        Expect.equal(of.viewers[1].set:get(ID)[POS], HIGH)
    end),

    -- A clear forgets what a streamed field last sent as well as the records, so a record added
    -- again into the same slot and moved to the value the slot last streamed is streamed again
    -- rather than taken as already told.
    Harness.case("set.newest-streams-again-after-clear", function()
        local of = opened(streamed)
        local set = Replica.ours(of)
        set:add(ID, record())
        Replica.ships(of)
        set:update(ID, { [POS] = HIGH })
        Replica.ships(of)
        Expect.equal(of.viewers[1].set:get(ID)[POS], HIGH)

        set:clear()
        Replica.ships(of)
        Expect.equal(of.viewers[1].set:get(ID), nil)

        set:add(ID, record())
        Replica.ships(of)
        set:update(ID, { [POS] = HIGH })
        Replica.ships(of)
        Expect.equal(of.viewers[1].set:get(ID)[POS], HIGH)
    end),

    -- What `old` is: the record as the viewer held it before this flush, one step back however
    -- many updates the flush folded together.
    Harness.case("set.changed-old", function()
        local of = opened(defined)
        local set = Replica.ours(of)
        set:add(ID, record())
        Replica.ships(of)
        set:update(ID, { [HP] = HIGH })
        set:update(ID, { [HP] = LOW })
        Replica.ships(of)

        Expect.equal(of.seen[2].kind, "changed")
        Expect.equal(of.seen[2].old[HP], START)
        Expect.equal(of.seen[2].old[POS], START)
        Expect.equal(of.seen[2].record[HP], LOW)
    end),

    -- A record added and taken away again before anybody was told. Nothing ships.
    Harness.case("set.add-remove", function()
        local of = opened(defined)
        local set = Replica.ours(of)
        set:add(ID, record())
        set:remove(ID)

        local before = Replica.carried(of)
        Replica.ships(of)
        Expect.equal(Replica.carried(of), before)
        Expect.equal(#of.seen, 0)
        Expect.equal(#of.viewers[1].set, 0)
    end),

    -- A record added and then changed before anybody was told: one arrival, carrying the later
    -- value.
    Harness.case("set.add-update", function()
        local of = opened(defined)
        local set = Replica.ours(of)
        set:add(ID, record())
        set:update(ID, { [HP] = HIGH })
        Replica.ships(of)

        Expect.equal(#of.seen, 1)
        Expect.equal(of.seen[1].kind, "added")
        Expect.equal(of.seen[1].record[HP], HIGH)
        Expect.equal(of.seen[1].record[POS], START)
    end),

    -- One id removed and added again in one flush is a different record wearing an old name: two
    -- tellings in that order rather than a change.
    Harness.case("set.replace", function()
        local of = opened(defined)
        local set = Replica.ours(of)
        set:add(ID, record())
        Replica.ships(of)
        set:remove(ID)
        set:add(ID, { [HP] = HIGH, [POS] = HIGH })
        Replica.ships(of)

        Expect.equal(#of.seen, 3)
        Expect.equal(of.seen[2].kind, "removed")
        Expect.equal(of.seen[2].cause, REMOVED)
        Expect.equal(of.seen[3].kind, "added")
        Expect.equal(of.seen[3].record[HP], HIGH)
    end),

    -- One flush carrying all three: removals lead, arrivals come before differences.
    Harness.case("set.flush-order", function()
        local of = opened(defined)
        local set = Replica.ours(of)
        set:add(ID, record())
        set:add(OTHER, record())
        Replica.ships(of)

        local was = #of.seen
        set:remove(ID)
        set:add(THIRD, record())
        set:update(OTHER, { [HP] = HIGH })
        Replica.ships(of)

        local held = table.move(of.seen, was + 1, #of.seen, 1, {})
        Expect.equal(#held, 3)
        Expect.equal(kinds(held), "removed added changed")
    end),

    -- A client that arrives after the records did is told an arrival for each record it may see.
    Harness.case("set.late-join", function()
        local of = opened(defined)
        local set = Replica.ours(of)
        set:add(ID, record())
        set:add(OTHER, record())
        Replica.ships(of)

        local late = Replica.joins(of, BOB)
        Expect.equal(#late.seen, 0)
        Replica.drains(of)

        Expect.equal(#late.seen, 2)
        Expect.equal(kinds(late.seen), "added added")
        Expect.equal(#late.set, 2)
    end),

    -- A late joiner catching up while the namespace keeps sending, which is the arrangement the
    -- catch-up reserve exists for.
    Harness.case("set.late-join-drains", function()
        local of = opened(heavy)
        local set = Replica.ours(of)
        for id = 1, MANY do
            set:add(id, laden())
        end
        Replica.drains(of)

        local late = Replica.joins(of, BOB)
        local rounds = 0
        for round = 1, LIMIT do
            -- A value that moves every round, since a set told what it already holds sends nothing.
            for id = 1, MANY do
                set:update(id, { [HP] = round % HIGH })
            end
            Replica.ships(of)
            rounds = round
            if #late.set == MANY then break end
        end

        Expect.holds(rounds >= SEVERAL, `the catch-up took {rounds} rounds, so nobody was behind`)
        Expect.equal(#late.set, MANY)
        Expect.equal(late.set:get(MANY)[NOTE], FILLED)
    end),

    -- A client gone from the game has nothing more addressed to it.
    Harness.case("set.viewer-leaves", function()
        local of = opened(defined)
        local set = Replica.ours(of)
        local held = of.viewers[1]
        set:add(ID, record())
        Replica.ships(of)

        local sent = 0
        local stop = of.wire:watch(function(frame: Doubles.Carried)
            if frame.to == held.player then
                sent += 1
            end
        end)
        Replica.leaves(of, held)
        set:add(OTHER, record())
        set:update(ID, { [HP] = HIGH })
        Replica.ships(of)
        stop()

        Expect.equal(sent, 0)
    end),

    -- A set nobody partitioned: every client holds every record.
    Harness.case("key.unkeyed-global", function()
        local of = opened(defined)
        local set = Replica.ours(of)
        local bob = Replica.joins(of, BOB)
        set:add(ID, record())
        set:add(OTHER, record())
        Replica.drains(of)

        for _, held in of.viewers do
            Expect.equal(#held.set, 2)
            Expect.holds(held.set:get(ID) ~= nil, `{held.player.Name} is missing a record`)
            Expect.holds(held.set:get(OTHER) ~= nil, `{held.player.Name} is missing one`)
        end
        Expect.equal(#bob.seen, 2)
    end),

    -- A key granted to somebody: only they hold the records under it, and a key nobody granted
    -- reaches nobody, so a forgotten audience hides records rather than leaks them.
    Harness.case("key.audience-grants", function()
        local of = opened(Schemas.roster)
        local set = Replica.ours(of)
        local alice, bob = of.viewers[1], Replica.joins(of, BOB)
        set:add(ID, teamed(RED))
        set:add(OTHER, teamed(BLUE))
        set:audience(RED, alice.player)
        Replica.drains(of)

        Expect.holds(alice.set:get(ID) ~= nil, "the grantee is missing its own key's record")
        Expect.equal(bob.set:get(ID), nil)
        Expect.equal(alice.set:get(OTHER), nil)
        Expect.equal(bob.set:get(OTHER), nil)
    end),

    -- A key granted twice: the second call is what the audience is, so whoever held it before is
    -- told the records went, as a removal since nothing on the wire says why.
    Harness.case("key.audience-replaces", function()
        local of = opened(Schemas.roster)
        local set = Replica.ours(of)
        local alice, bob = of.viewers[1], Replica.joins(of, BOB)
        set:add(ID, teamed(RED))
        set:audience(RED, alice.player)
        Replica.drains(of)
        Expect.holds(alice.set:get(ID) ~= nil, "the first grantee never held the record")

        local was = #alice.seen
        set:audience(RED, bob.player)
        Replica.drains(of)

        Expect.equal(alice.set:get(ID), nil)
        Expect.holds(bob.set:get(ID) ~= nil, "the second grantee never held the record")
        Expect.equal(#alice.seen, was + 1)
        Expect.equal(alice.seen[was + 1].kind, "removed")
        Expect.equal(alice.seen[was + 1].id, ID)
    end),

    -- A streamed field with a rate on it, written faster than the rate lets it out. `hz` caps how
    -- often a field goes out and not how often a place may write one.
    Harness.case("set.streamed-rate", function()
        local of = opened(paced)
        local set = Replica.ours(of)
        set:add(1, { [HP] = 1, [POS] = 1 })
        Replica.ships(of)

        local was = Replica.crossed(of)
        for step = 1, RAPID do
            set:update(1, { [POS] = step })
            Replica.ships(of)
        end
        local frames = Replica.crossed(of) - was
        Expect.holds(frames > 0, "a streamed field with a rate on it moved nothing at all")
        Expect.holds(frames <= LETS, `a rate of {RATE} let {frames} of {RAPID} flushes through`)
    end),

    -- A set emptied and filled again, with a field that streams and records enough that the stream
    -- walks the partition over several flushes. What the set holds afterwards is what was written
    -- after the clear, under every id.
    Harness.case("set.clear-sweeps-streams", function()
        local of = opened(streamed)
        local set = Replica.ours(of)
        local held = of.viewers[1].set
        for id = 1, MANY do
            set:add(id, { [HP] = 1, [POS] = 1 })
        end
        for _ = 1, DRAINS do
            set:update(1, { [POS] = 2 })
            Replica.ships(of)
        end

        set:clear()
        Replica.ships(of)
        Expect.equal(#held, 0)

        for id = 1, MANY do
            set:add(id, { [HP] = 2, [POS] = 1 })
        end
        Replica.ships(of)
        -- Streamed after the refill, since an add carries every field and asks the stream nothing.
        for id = 1, MANY do
            set:update(id, { [POS] = 3 })
        end
        for _ = 1, DRAINS do
            Replica.ships(of)
        end

        for id = 1, MANY do
            local one = held:get(id)
            Expect.holds(one ~= nil, `a record filled after a clear reached nobody under {id}`)
            Expect.equal(one[POS], 3)
        end
    end),

    -- Each telling asked for on its own, since a set works out what a frame did only for somebody
    -- who asked. Three runs, one callback apiece.
    Harness.case("set.one-listener-at-a-time", function()
        local function alone(): Run
            return Replica.open({ space = SPACE, defined = defined }, ALICE)
        end

        local added = alone()
        local told = 0
        added.client.defs[ROSTER]:onAdded(function()
            told += 1
        end)
        added.server.defs[ROSTER]:add(ID, record())
        Replica.ships(added)
        Expect.equal(told, 1)

        local changed = alone()
        told = 0
        changed.client.defs[ROSTER]:onChanged(function()
            told += 1
        end)
        changed.server.defs[ROSTER]:add(ID, record())
        Replica.ships(changed)
        changed.server.defs[ROSTER]:update(ID, { [HP] = HIGH })
        Replica.ships(changed)
        Expect.equal(told, 1)

        local removed = alone()
        local why: Types.Cause? = nil
        removed.client.defs[ROSTER]:onRemoved(function(_id: number, cause: Types.Cause)
            why = cause
        end)
        removed.server.defs[ROSTER]:add(ID, record())
        Replica.ships(removed)
        removed.server.defs[ROSTER]:remove(ID)
        Replica.ships(removed)
        Expect.equal(why, REMOVED)
    end),

    -- An add and an update folded into one flush, where the field moved rides the lossy lane. A
    -- record cannot change into existence, so what a viewer is owed is a single arrival already
    -- carrying the later value.
    Harness.case("set.arrival-outlives-a-stream", function()
        local of = opened(streamed)
        local set = Replica.ours(of)
        set:add(ID, record())
        set:update(ID, { [POS] = HIGH })
        Replica.ships(of)

        Expect.equal(kinds(of.seen), "added")
        Expect.equal(of.seen[1].record[POS], HIGH)
        Expect.equal(of.viewers[1].set:get(ID)[POS], HIGH)
    end),

    -- A settle whose listener comes apart on one record of several: the records of a settle share
    -- the thread a listener is called on, and sharing the thread is all they share.
    Harness.case("set.telling-outlives-one-that-comes-apart", function()
        local of = opened(defined)
        local set = Replica.ours(of)
        for id = 1, FEW do
            set:add(id, record())
        end
        Replica.ships(of)

        local seen: { number } = {}
        of.client.defs[ROSTER]:onChanged(function(id: number)
            table.insert(seen, id)
            if id == BREAKS then error("this one came apart", 0) end
        end)
        for id = 1, FEW do
            set:update(id, { [HP] = HIGH })
        end
        Replica.ships(of)

        Expect.equal(#seen, FEW)
        Expect.equal(seen[FEW], FEW)
    end),
}
