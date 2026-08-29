--!strict
--!optimize 2
--[[
    A person who leaves and comes back: a new Player, an empty view, and none of what the one before
    them was granted.
]]

local Lync = require ("@src")

local Doubles = require ("@fixtures/Doubles")
local Schemas = require ("@fixtures/Schemas")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Replica = require ("@test/harness/Replica")

-- Constants -----------------------------------------------------------

const SPACE = "rejoin"

-- The person who leaves and comes back, and the one who stays.
const SENDER = "alice"
const WATCHER = "bob"

-- A third machine, which arrives once a key has already been named everybody's.
const LATE = "carol"

-- The set, keyed by a field, because a grant is per key and a set with no key grants everything.
const ROSTER = Schemas.ROSTER
const TEAM = Schemas.TEAM
const HP = Schemas.HP

--[[
    Two keys, one granted to people and the other to nobody. The second is what makes a grant a
    partition rather than a switch, since a library handing the whole set to anyone with an audience
    answers every reading below and the records nobody may see are what catch it.
]]
const RED = Schemas.RED
const BLUE = Schemas.BLUE

const REDS = table.freeze ({ 1, 2 })
const BLUES = table.freeze ({ 3, 4 })

-- What a record carries besides the key it sits under, and the bound on it.
const START = 100

-- What a record moves to, so a reading of it says which of the two flushes it came from.
const MOVED = 50

-- The two ways a viewer is told, named so a reading says which it asked about.
const ADDED = "added"
const REMOVED = "removed"

-- The bound a drain here is held to, read from its one home rather than spelled again.
const ROUNDS = Doubles.ROUNDS

-- Types ---------------------------------------------------------------

type Run = Replica.Alone
type Seen = Replica.Seen
type Viewer = Replica.Viewer

-- Private -------------------------------------------------------------

--[[
    The opening every run here is made from, which is a server and nobody watching it yet.

    Nobody, because every viewer here arrives after the records do and one of them arrives twice.
]]
const OPENS: Replica.Opening = { space = SPACE, defined = Schemas.roster, watched = ROSTER }

-- A player leaving the game, which is the roster losing them and nothing else.
local function leaving (of: Run, held: Viewer)
    of.roster:leave (held.player)
    of.wire:gone (held.player)
end

-- Who sees a key's records, written as a caller writes it and resolved when a flush goes out.
local function granted (of: Run, key: string, to: { Player })
    local set = Replica.ours (of)
    set:audience (key, to)
end

--[[
    Two records on each key, so a grant is a partition of the set rather than the whole of it, and
    the key that is nobody's said to be nobody's.
]]
local function stocks (of: Run)
    for _, id in REDS do
        Replica.ours (of):add (id, { [TEAM] = RED, [HP] = START })
    end
    for _, id in BLUES do
        Replica.ours (of):add (id, { [TEAM] = BLUE, [HP] = START })
    end

    Replica.ours (of):audience (BLUE, {})
end

-- Flushes until nothing more arrives anywhere.
local function ships (of: Run)
    local count = -1
    for _ = 1, ROUNDS do
        local now = 0
        for _, held in of.viewers do
            now += #held.set
        end
        if now == count then return end

        count = now
        of.server.session:flush ()
        of.wire:settle ()
    end

    Expect.holds (false, `the set was still draining after {ROUNDS} flushes`)
end

-- Every record a viewer holds, by id, which is the view its audiences decided.
local function holding (of: Viewer): { number }
    local ids = {}
    for id in of.set do
        table.insert (ids, id)
    end

    table.sort (ids)
    return ids
end

-- Every id a viewer was told about one way, in id order, since the last thing it forgot.
local function told (of: Viewer, kind: string): { number }
    local ids = {}
    for _, one in of.seen do
        if one.kind == kind then table.insert (ids, one.id) end
    end

    table.sort (ids)
    return ids
end

-- Public --------------------------------------------------------------

return {
    --[[
        The same person, twice, with a grant in between. A Player is an identity rather than a name,
        so somebody who reconnects is a new Instance holding nothing while every audience the old
        one was in still names the old one.
    ]]
    Harness.case ("set.returns", function ()
        local of = Replica.serves (OPENS)
        stocks (of)

        local bob = Replica.joins (of, WATCHER)
        local alice = Replica.joins (of, SENDER)

        granted (of, RED, { alice.player, bob.player })
        ships (of)

        Expect.equal (holding (alice), REDS)
        Expect.equal (holding (bob), REDS)
        Expect.equal (told (bob, ADDED), REDS)
        Replica.forgets (bob)

        leaving (of, alice)
        local fresh = Replica.joins (of, SENDER)
        ships (of)

        Expect.holds (fresh.player ~= alice.player, "the roster handed back the player that left")
        Expect.equal (holding (fresh), {})
        Expect.equal (told (fresh, ADDED), {})
        Expect.equal (told (fresh, REMOVED), {})
        Expect.equal (holding (bob), REDS)
        Expect.equal (told (bob, ADDED), {})
        Expect.equal (told (bob, REMOVED), {})
        Replica.forgets (bob)

        granted (of, RED, { fresh.player, bob.player })
        ships (of)

        Expect.equal (holding (fresh), REDS)
        Expect.equal (told (fresh, ADDED), REDS)
        Expect.equal (holding (bob), REDS)
        Expect.equal (told (bob, ADDED), {})
    end),

    --[[
        Two keys in one run, one arriving and one moving. A key is a partition of its own and a
        slot is a number inside one, so the same number names a record in each, and what a
        receiver holds after both is every record of both rather than whichever was spoken for
        first.
    ]]
    Harness.case ("set.partitions-are-shadowed-apart", function ()
        local of = Replica.open (OPENS, SENDER)
        local set = Replica.ours (of)

        granted (of, RED, { of.player })
        granted (of, BLUE, { of.player })

        -- Drained, so what follows is a record moving rather than one still on its way over.
        set:add (BLUES[1], { [TEAM] = BLUE, [HP] = START })
        ships (of)

        local held = of.viewers[1].set
        Expect.equal (held:get (BLUES[1])[HP], START)

        -- The first record on red, and the record on blue moving, inside the one flush.
        set:add (REDS[1], { [TEAM] = RED, [HP] = START })
        set:update (BLUES[1], { [HP] = MOVED })
        ships (of)

        Expect.holds (held:get (REDS[1]) ~= nil, "a record arriving on one key reached nobody")
        Expect.equal (held:get (BLUES[1])[HP], MOVED)
    end),

    --[[
        A key handed to one machine, then to everybody, then to another one. What a grant names is
        who a partition is for, so widening it has to reach the machines that were never named and
        narrowing it again has to take it back off them. A key that stayed wide once it had been
        wide would go on sending to whoever happened to be holding it when the caller narrowed it.
    ]]
    Harness.case ("set.a-key-widens-and-narrows", function ()
        local of = Replica.open (OPENS, SENDER)
        local bob = Replica.joins (of, WATCHER)
        local set = Replica.ours (of)

        for _, id in REDS do
            set:add (id, { [TEAM] = RED, [HP] = START })
        end

        granted (of, RED, { of.player })
        ships (of)

        local alice = of.viewers[1]
        Expect.equal (told (alice, ADDED), REDS)
        Expect.equal (told (bob, ADDED), {})

        -- Named everybody, which reaches the machine that was never one of its holders.
        set:audience (RED, Lync.all)
        ships (of)
        Expect.equal (told (bob, ADDED), REDS)

        --[[
            A machine arriving after the key was named everybody, which is what tells everybody
            apart from the holders it happened to have: a list is who was named when it was
            written, and everybody is whoever is here when the flush goes out.
        ]]
        local late = Replica.joins (of, LATE)
        ships (of)
        Expect.equal (told (late, ADDED), REDS)

        -- Named one machine again, which takes it back off the ones no longer named.
        set:audience (RED, { bob.player })
        ships (of)
        Expect.equal (told (alice, REMOVED), REDS)
        Expect.equal (told (bob, REMOVED), {})
    end),
}
