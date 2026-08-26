--!strict
--!optimize 2
--[[
    A person who leaves and comes back: a new Player, an empty view, and none of what the one before
    them was granted.
]]

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
}
