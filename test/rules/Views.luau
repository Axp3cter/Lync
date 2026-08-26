--!strict
--!optimize 2
-- What a viewer holds and what it was told, one promise at a time.

local Lync = require ("@src")
local Types = require ("@src/Types")

local Doubles = require ("@fixtures/Doubles")
local Schemas = require ("@fixtures/Schemas")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Replica = require ("@test/harness/Replica")

-- Constants -----------------------------------------------------------

const SPACE = "views"

-- Two clients, because a claim about who holds a record needs somebody who does not.
const ALICE = "alice"
const BOB = "bob"

const ROSTER = Schemas.ROSTER

-- One unkeyed record: a number that changes and a second that stays, so a delta names one field.
const HP = Schemas.HP
const POS = "pos"

-- The keyed record's partition field and the two keys a check grants.
const TEAM = Schemas.TEAM
const RED = Schemas.RED
const BLUE = Schemas.BLUE

-- The ids a check names, and the values it moves them between.
const ID = 1
const OTHER = 2
const THIRD = 3

const START = 10
const HIGH = 90
const LOW = 20

const REMOVED: Types.Cause = "removed"
const CLEARED: Types.Cause = "cleared"

--[[
    A lane that hands every frame over twice, which is the one thing an unordered lane does that
    nothing else here asks for.
]]
const DOUBLING: Doubles.Faults = table.freeze ({ lose = 0, double = 1, hold = 0 })

-- More records than one flush at the floor budget can carry, and how wide each of them is.
const MANY = 200

--[[
    A cap on how often a streamed field goes out, and how many flushes a check drives past it. Four
    a second is a quarter second a window, and a handful of flushes in a row is over in far less
    than that whichever clock is under them, so every flush but the first falls inside one window.
]]
const RATE = 4
const RAPID = 5

--[[
    The most a run that short may put on the wire. One window holds all of it, so what a rate lets
    through is the first and nothing after it, and the second is room for a run that opened just as
    a window closed. A lane with no rate under it sends nearly every flush and is well past this.
]]
const LETS = 2

-- Flushes enough to walk a partition of `MANY` end to end however few slots one section takes.
const DRAINS = 24
const NOTE = "note"
const WIDTH = 64
const FILLED = string.rep ("x", WIDTH)

-- More than one, which is the whole of what makes a late joiner behind rather than merely late.
const SEVERAL = 2

-- Where a catch-up that is not making progress is called one, read from its one home.
const LIMIT = Doubles.ROUNDS
const EVERY_FRAME = table.freeze ({ Doubles.FAULTED })

-- Types ---------------------------------------------------------------

type Seen = Replica.Seen
type Run = Replica.Run

-- Private -------------------------------------------------------------

--[[
    An unkeyed set, which is the shape most of these read on. Two fields rather than one, so an
    update naming one of them is a delta and a check can tell a keyframe from a difference.
]]
local function defined (): any
    return {
        [ROSTER] = Lync.replicate (Lync.struct ({
            [HP] = Lync.int (0, 100),
            [POS] = Lync.int (0, 100),
        })),
    }
end

--[[
    The same set with a field that rides the lossy lane, which is where a replay can reach.

    `pos` rather than `hp`, so the field that streams is not the field every other check here moves,
    and a run that confused the two would be reading a delta on the reliable lane.
]]
local function streamed (): any
    return {
        [ROSTER] = Lync.replicate (Lync.struct ({
            [HP] = Lync.int (0, 100),
            [POS] = Lync.int (0, 100):newest (),
        })),
    }
end

-- The same streamed set, with the cap on how often the field that streams may go out.
local function paced (): any
    return {
        [ROSTER] = Lync.replicate (Lync.struct ({
            [HP] = Lync.int (0, 100),
            [POS] = Lync.int (0, 100):newest (RATE),
        })),
    }
end

--[[
    The same set with a field wide enough to make a flush choose, which is what a catch-up needs.

    One string beside the number, since what decides how many records a flush carries is what a
    record costs and a set of two small numbers costs almost nothing.
]]
local function heavy (): any
    return {
        [ROSTER] = Lync.replicate (Lync.struct ({
            [HP] = Lync.int (0, 100),
            [NOTE] = Lync.str (0, WIDTH),
        })),
    }
end

local function laden (): any return { [HP] = START, [NOTE] = FILLED } end

local function record (): any return { [HP] = START, [POS] = START } end

local function teamed (side: string): any return { [TEAM] = side, [HP] = START } end

local function opened (built: () -> any): Run
    return Replica.open ({ space = SPACE, defined = built, watched = ROSTER }, ALICE)
end

-- Every telling, as the kinds in the order they arrived, which is what an order check compares.
local function kinds (seen: { Seen }): { string }
    local out = {}
    for _, one in seen do
        table.insert (out, one.kind)
    end
    return out
end

-- Public --------------------------------------------------------------

return {
    --[[
        A record added, which is the first thing a set does. The viewer is told once, with the id
        and the record, and it is told after the flush rather than at the call: an `add` is a
        change to what the server holds and a flush is what makes it a change to what anybody sees.
    ]]
    Harness.case ("set.add", function ()
        local of = opened (defined)

        Replica.ours (of):add (ID, record ())
        Expect.equal (#of.seen, 0)

        Replica.ships (of)
        Expect.equal (#of.seen, 1)
        Expect.equal (of.seen[1].kind, "added")
        Expect.equal (of.seen[1].id, ID)
        Expect.equal (of.seen[1].record[HP], START)
        Expect.equal (of.seen[1].record[POS], START)
    end),

    --[[
        A record removed, and the cause it carries. The two causes are the whole vocabulary, so a
        removal that named neither would leave a caller unable to tell a record going away from a
        set being emptied under it, which are different things to a place drawing what it holds.
    ]]
    Harness.case ("set.remove", function ()
        local of = opened (defined)
        local set = Replica.ours (of)

        set:add (ID, record ())
        Replica.ships (of)

        set:remove (ID)
        Replica.ships (of)

        Expect.equal (#of.seen, 2)
        Expect.equal (of.seen[2].kind, "removed")
        Expect.equal (of.seen[2].id, ID)
        Expect.equal (of.seen[2].cause, REMOVED)
        Expect.equal (of.viewers[1].set:get (ID), nil)
    end),

    --[[
        A set emptied. Every record the viewer held is a removal it is told about, and every one of
        them carries the other cause, which is what tells a caller that the set went rather than
        that the records did. Two records rather than one, so a clear reaching only the first would
        pass a check written about one.
    ]]
    Harness.case ("set.clear", function ()
        local of = opened (defined)
        local set = Replica.ours (of)

        set:add (ID, record ())
        set:add (OTHER, record ())
        Replica.ships (of)

        set:clear ()
        Replica.ships (of)

        Expect.equal (#of.seen, 4)
        local gone = {}
        for at = 3, 4 do
            Expect.equal (of.seen[at].kind, "removed")
            Expect.equal (of.seen[at].cause, CLEARED)
            gone[of.seen[at].id] = true
        end

        Expect.holds (gone[ID] and gone[OTHER], "a clear left a record behind")
        Expect.equal (#of.viewers[1].set, 0)
    end),

    --[[
        What `#set` counts. A client holds a view rather than the set, so the length is what it has
        been given and never what the server owns: a client reading the server's count would be a
        client that could tell how many records its audiences hide from it.
    ]]
    Harness.case ("set.len", function ()
        local of = opened (defined)
        local set = Replica.ours (of)
        local view = of.viewers[1].set

        Expect.equal (#view, 0)

        set:add (ID, record ())
        set:add (OTHER, record ())
        Expect.equal (#set, 2)
        Expect.equal (#view, 0)

        Replica.ships (of)
        Expect.equal (#view, 2)

        set:remove (ID)
        Replica.ships (of)
        Expect.equal (#view, 1)
    end),

    --[[
        Two updates to one field between flushes. What ships is where the field ended up rather than
        how it got there, so the viewer is told once and the value it is told is the last one: a
        library sending each step would spend a frame a call for a number nobody saw in between.
    ]]
    Harness.case ("set.changed-net", function ()
        local of = opened (defined)
        local set = Replica.ours (of)

        set:add (ID, record ())
        Replica.ships (of)

        set:update (ID, { [HP] = HIGH })
        set:update (ID, { [HP] = LOW })
        Replica.ships (of)

        Expect.equal (#of.seen, 2)
        Expect.equal (of.seen[2].kind, "changed")
        Expect.equal (of.seen[2].record[HP], LOW)
        Expect.equal (of.viewers[1].set:get (ID)[HP], LOW)
    end),

    --[[
        A streamed field whose section the lane hands over twice. The ring a newest stream is
        ordered by is what tells the second copy from the first, so the sequence it arrives under is
        one this client has already taken and there is nothing in it left to apply.
    ]]
    Harness.case ("set.newest-doubled", function ()
        local of = Replica.open ({
            space = SPACE,
            defined = streamed,
            watched = ROSTER,
            chance = DOUBLING,
            draw = Doubles.scripted (EVERY_FRAME),
        }, ALICE)

        local set = Replica.ours (of)
        set:add (ID, record ())
        Replica.ships (of)

        local before = #of.seen
        set:update (ID, { [POS] = HIGH })
        Replica.ships (of)

        local doubled = of.wire:moved ().doubled
        Expect.holds (doubled > 0, "the lane was asked to double and doubled nothing")

        Expect.equal (#of.seen - before, 1)
        Expect.equal (of.seen[#of.seen].kind, "changed")
        Expect.equal (of.seen[#of.seen].record[POS], HIGH)
        Expect.equal (of.viewers[1].set:get (ID)[POS], HIGH)
    end),

    --[[
        What `old` is. A caller drawing a change wants what it was as well as what it is, and the
        only honest reading of that is the record as the viewer held it before this flush, which is
        one step back however many updates the flush folded together.
    ]]
    Harness.case ("set.changed-old", function ()
        local of = opened (defined)
        local set = Replica.ours (of)

        set:add (ID, record ())
        Replica.ships (of)

        set:update (ID, { [HP] = HIGH })
        set:update (ID, { [HP] = LOW })
        Replica.ships (of)

        Expect.equal (of.seen[2].kind, "changed")
        Expect.equal (of.seen[2].old[HP], START)
        Expect.equal (of.seen[2].old[POS], START)
        Expect.equal (of.seen[2].record[HP], LOW)
    end),

    --[[
        A record added and taken away again before anybody was told. Nothing ships, because the
        viewer's own state is what a flush is a difference against and this made no difference to
        it. A library sending both would make a spawn that failed cost two frames a viewer.
    ]]
    Harness.case ("set.add-remove", function ()
        local of = opened (defined)
        local set = Replica.ours (of)

        set:add (ID, record ())
        set:remove (ID)

        local before = Replica.carried (of)
        Replica.ships (of)

        Expect.equal (Replica.carried (of), before)
        Expect.equal (#of.seen, 0)
        Expect.equal (#of.viewers[1].set, 0)
    end),

    --[[
        A record added and then changed before anybody was told. One telling rather than two, and it
        is an arrival rather than a change, because a viewer that never held the first values has
        nothing for a difference to be a difference from.
    ]]
    Harness.case ("set.add-update", function ()
        local of = opened (defined)
        local set = Replica.ours (of)

        set:add (ID, record ())
        set:update (ID, { [HP] = HIGH })
        Replica.ships (of)

        Expect.equal (#of.seen, 1)
        Expect.equal (of.seen[1].kind, "added")
        Expect.equal (of.seen[1].record[HP], HIGH)
        Expect.equal (of.seen[1].record[POS], START)
    end),

    --[[
        One id removed and added again in one flush, which is a different record wearing a name the
        old one had. Two tellings in that order rather than a change, since the values a caller
        would be handed as `old` belong to a record that is gone and a change carrying them would
        say a thing became something it never was.
    ]]
    Harness.case ("set.replace", function ()
        local of = opened (defined)
        local set = Replica.ours (of)

        set:add (ID, record ())
        Replica.ships (of)

        set:remove (ID)
        set:add (ID, { [HP] = HIGH, [POS] = HIGH })
        Replica.ships (of)

        Expect.equal (#of.seen, 3)
        Expect.equal (of.seen[2].kind, "removed")
        Expect.equal (of.seen[2].cause, REMOVED)
        Expect.equal (of.seen[3].kind, "added")
        Expect.equal (of.seen[3].record[HP], HIGH)
    end),

    --[[
        One flush carrying all three, and the order they arrive in. Removals lead, so an id freed
        and taken again in the same flush is never two records at once, and arrivals come before
        differences, so nothing is a difference against a record the viewer has not been given yet.
    ]]
    Harness.case ("set.flush-order", function ()
        local of = opened (defined)
        local set = Replica.ours (of)

        set:add (ID, record ())
        set:add (OTHER, record ())
        Replica.ships (of)

        local was = #of.seen
        set:remove (ID)
        set:add (THIRD, record ())
        set:update (OTHER, { [HP] = HIGH })
        Replica.ships (of)

        local held = {}
        for at = was + 1, #of.seen do
            table.insert (held, of.seen[at])
        end

        Expect.equal (#held, 3)
        Expect.equal (table.concat (kinds (held), " "), "removed added changed")
    end),

    --[[
        A client that arrives after the records did. What it is told is an arrival for each record
        it may see, because a viewer's first sight of a record is an arrival however old the record
        is, and a library that said nothing would leave a late joiner drawing an empty world.
    ]]
    Harness.case ("set.late-join", function ()
        local of = opened (defined)
        local set = Replica.ours (of)

        set:add (ID, record ())
        set:add (OTHER, record ())
        Replica.ships (of)

        local late = Replica.joins (of, BOB)
        Expect.equal (#late.seen, 0)

        Replica.drains (of)

        Expect.equal (#late.seen, 2)
        Expect.equal (table.concat (kinds (late.seen), " "), "added added")
        Expect.equal (#late.set, 2)
    end),

    --[[
        A late joiner catching up while the namespace keeps sending, which is the arrangement the
        catch-up reserve exists for and the one nothing here had built.
    ]]
    Harness.case ("set.late-join-drains", function ()
        local of = opened (heavy)
        local set = Replica.ours (of)

        for id = 1, MANY do
            set:add (id, laden ())
        end
        Replica.drains (of)

        local late = Replica.joins (of, BOB)

        local rounds = 0
        for round = 1, LIMIT do
            -- A value that moves every round, since a set told what it already holds sends nothing.
            for id = 1, MANY do
                set:update (id, { [HP] = round % HIGH })
            end

            Replica.ships (of)
            rounds = round
            if #late.set == MANY then break end
        end

        Expect.holds (rounds >= SEVERAL, `the catch-up took {rounds} rounds, so nobody was behind`)
        Expect.equal (#late.set, MANY)
        Expect.equal (late.set:get (MANY)[NOTE], FILLED)
    end),

    --[[
        A client gone from the game. Nothing more is addressed to it, which is a claim about the
        lane rather than about the client: a library still composing frames for somebody who left
        would spend a partition a flush on a machine nobody is holding.
    ]]
    Harness.case ("set.viewer-leaves", function ()
        local of = opened (defined)
        local set = Replica.ours (of)
        local held = of.viewers[1]

        set:add (ID, record ())
        Replica.ships (of)

        local sent = 0
        local stop = of.wire:watch (function (frame)
            if frame.to == held.player then
                sent += 1
            end
        end)

        Replica.leaves (of, held)
        set:add (OTHER, record ())
        set:update (ID, { [HP] = HIGH })
        Replica.ships (of)
        stop ()

        Expect.equal (sent, 0)
    end),

    --[[
        A set nobody partitioned. Every client holds every record, which is the reading a set with
        no `keyBy` has: there is one audience and it is everybody, so two clients that were told
        different things would be a library inventing a partition nobody declared.
    ]]
    Harness.case ("key.unkeyed-global", function ()
        local of = opened (defined)
        local set = Replica.ours (of)
        local bob = Replica.joins (of, BOB)

        set:add (ID, record ())
        set:add (OTHER, record ())
        Replica.drains (of)

        for _, held in of.viewers do
            Expect.equal (#held.set, 2)
            Expect.holds (held.set:get (ID) ~= nil, `{held.player.Name} is missing a record`)
            Expect.holds (held.set:get (OTHER) ~= nil, `{held.player.Name} is missing one`)
        end
        Expect.equal (#bob.seen, 2)
    end),

    --[[
        A key granted to somebody. Only they hold the records under it, and the grant is described
        as leaving them holding it rather than as adding them to it, which is the surface's own
        reading and is what makes a first grant a taking away from everybody else.
    ]]
    Harness.case ("key.audience-grants", function ()
        local of = opened (Schemas.roster)
        local set = Replica.ours (of)
        local alice, bob = of.viewers[1], Replica.joins (of, BOB)

        set:add (ID, teamed (RED))
        set:add (OTHER, teamed (BLUE))
        set:audience (RED, alice.player)
        Replica.drains (of)

        Expect.holds (alice.set:get (ID) ~= nil, "the grantee is missing its own key's record")
        Expect.equal (bob.set:get (ID), nil)

        -- And the key nobody narrowed is still everybody's, so this is a grant and not a fence.
        Expect.holds (alice.set:get (OTHER) ~= nil, "an ungranted key stopped reaching alice")
        Expect.holds (bob.set:get (OTHER) ~= nil, "an ungranted key stopped reaching bob")
    end),

    --[[
        A key granted twice. The second call is what the key's audience is rather than an addition
        to it, so whoever held it before is told the records went. The cause is a removal, since
        from the losing client the record is gone and nothing on the wire says why.
    ]]
    Harness.case ("key.audience-replaces", function ()
        local of = opened (Schemas.roster)
        local set = Replica.ours (of)
        local alice, bob = of.viewers[1], Replica.joins (of, BOB)

        set:add (ID, teamed (RED))
        set:audience (RED, alice.player)
        Replica.drains (of)

        Expect.holds (alice.set:get (ID) ~= nil, "the first grantee never held the record")
        local was = #alice.seen

        set:audience (RED, bob.player)
        Replica.drains (of)

        Expect.equal (alice.set:get (ID), nil)
        Expect.holds (bob.set:get (ID) ~= nil, "the second grantee never held the record")

        Expect.equal (#alice.seen, was + 1)
        Expect.equal (alice.seen[was + 1].kind, "removed")
        Expect.equal (alice.seen[was + 1].id, ID)
    end),

    --[[
        A streamed field with a rate on it, written faster than the rate lets it out. `hz` caps how
        often a field goes out and not how often a place may write one, so writing every frame is
        the thing a rate exists for, and a lane putting every write on the wire is a lane that
        never had a rate at all.
    ]]
    Harness.case ("set.streamed-rate", function ()
        local of = opened (paced)
        local set = Replica.ours (of)

        set:add (1, { [HP] = 1, [POS] = 1 })
        Replica.ships (of)

        local was = Replica.crossed (of)
        for step = 1, RAPID do
            set:update (1, { [POS] = step })
            Replica.ships (of)
        end

        local frames = Replica.crossed (of) - was
        Expect.holds (frames > 0, "a streamed field with a rate on it moved nothing at all")
        Expect.holds (frames <= LETS, `a rate of {RATE} let {frames} of {RAPID} flushes through`)
    end),

    --[[
    A set emptied and filled again, with a field that streams and records enough that the stream
    walks the partition over several flushes. What the set holds afterwards is what was written
    after the clear, under every id, rather than anything the partition stood at before it.
]]
    Harness.case ("set.clear-sweeps-streams", function ()
        local of = opened (streamed)
        local set = Replica.ours (of)
        local held = of.viewers[1].set

        --[[
            Enough records that a stream walks the partition over more flushes than one, since a
            mark that resumes where the last flush stopped only matters where there is a next one.
        ]]
        for id = 1, MANY do
            set:add (id, { [HP] = 1, [POS] = 1 })
        end
        for _ = 1, DRAINS do
            set:update (1, { [POS] = 2 })
            Replica.ships (of)
        end

        set:clear ()
        Replica.ships (of)
        Expect.equal (#held, 0)

        for id = 1, MANY do
            set:add (id, { [HP] = 2, [POS] = 1 })
        end
        Replica.ships (of)

        -- Streamed after the refill, since an add carries every field and asks the stream nothing.
        for id = 1, MANY do
            set:update (id, { [POS] = 3 })
        end
        for _ = 1, DRAINS do
            Replica.ships (of)
        end

        for id = 1, MANY do
            local one = held:get (id)
            Expect.holds (one ~= nil, `a record filled after a clear reached nobody under {id}`)
            Expect.equal (one[POS], 3)
        end
    end),

    --[[
        Each telling asked for on its own, since a set works out what a frame did only for somebody
        who asked. Every other check here connects all three at once, which cannot tell a set that
        asks whether anything listens from one that asks whether this listens: three runs, one
        callback apiece, is what separates them.
    ]]
    Harness.case ("set.one-listener-at-a-time", function ()
        --[[
            Nobody watching, so the only listener on the client is the one each turn connects. A
            run that watched would have all three attached before the check began.
        ]]
        local function alone (): Run
            return Replica.open ({ space = SPACE, defined = defined }, ALICE)
        end

        do
            local of = alone ()
            local ours = of.server.defs[ROSTER]
            local told = 0

            of.client.defs[ROSTER]:onAdded (function ()
                told += 1
            end)
            ours:add (ID, record ())
            Replica.ships (of)

            Expect.equal (told, 1)
        end

        do
            local of = alone ()
            local ours = of.server.defs[ROSTER]
            local told = 0

            of.client.defs[ROSTER]:onChanged (function ()
                told += 1
            end)
            ours:add (ID, record ())
            Replica.ships (of)

            ours:update (ID, { [HP] = HIGH })
            Replica.ships (of)

            Expect.equal (told, 1)
        end

        do
            local of = alone ()
            local ours = of.server.defs[ROSTER]
            local told: Types.Cause? = nil

            of.client.defs[ROSTER]:onRemoved (
                function (_id: number, why: Types.Cause) told = why end
            )
            ours:add (ID, record ())
            Replica.ships (of)

            ours:remove (ID)
            Replica.ships (of)

            Expect.equal (told, REMOVED)
        end
    end),
}
