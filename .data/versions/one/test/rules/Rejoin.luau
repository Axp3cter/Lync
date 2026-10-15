--!strict
--!optimize 2
-- A person who leaves and comes back: a new Player, an empty view, and none of what the one before
-- them was granted.

local Recipients = require("@src/channel/Recipients")

local Doubles = require("@fixtures/Doubles")
local Schemas = require("@fixtures/Schemas")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Replica = require("@test/harness/Replica")

local SPACE = "rejoin"

-- The person who leaves and comes back, the one who stays, and a third machine that arrives once a
-- key has already been named everybody's.
local SENDER = "alice"
local WATCHER = "bob"
local LATE = "carol"

-- The set, keyed by a field, because a grant is per key and a set with no key grants everything.
local ROSTER = Schemas.ROSTER
local TEAM = Schemas.TEAM
local HP = Schemas.HP

-- Two keys, one granted to people and the other to nobody, which is what makes a grant a
-- partition rather than a switch.
local RED = Schemas.RED
local BLUE = Schemas.BLUE
local REDS = table.freeze({ 1, 2 })
local BLUES = table.freeze({ 3, 4 })

-- What a record carries besides the key it sits under, and what it moves to.
local START = 100
local MOVED = 50

-- The two ways a viewer is told, named so a reading says which it asked about.
local ADDED = "added"
local REMOVED = "removed"

local ROUNDS = Doubles.ROUNDS

-- The opening every run here is made from: a server and nobody watching it yet, since every viewer
-- here arrives after the records do and one of them arrives twice.
local OPENS: Replica.Opening = { space = SPACE, defined = Schemas.roster, watched = ROSTER }

type Run = Replica.Alone
type Viewer = Replica.Viewer

-- Private -------------------------------------------------------------

local function teamed(side: string): any
    return { [TEAM] = side, [HP] = START }
end

-- Two records on each key, so a grant is a partition of the set rather than the whole of it, and
-- the key that is nobody's said to be nobody's.
local function stocks(of: Run)
    local set = Replica.ours(of)
    for _, id in REDS do
        set:add(id, teamed(RED))
    end
    for _, id in BLUES do
        set:add(id, teamed(BLUE))
    end
    set:audience(BLUE, {})
end

-- Flushes until nothing more arrives anywhere.
local function ships(of: Run)
    local count = -1
    for _ = 1, ROUNDS do
        local now = 0
        for _, held in of.viewers do
            now += #held.set
        end
        if now == count then return end
        count = now
        of.server.session:flush()
        of.wire:settle()
    end
    Expect.holds(false, `the set was still draining after {ROUNDS} flushes`)
end

-- Every record a viewer holds, by id, which is the view its audiences decided.
local function holding(of: Viewer): { number }
    local ids = {}
    for id in of.set do
        table.insert(ids, id)
    end
    table.sort(ids)
    return ids
end

-- Every id a viewer was told about one way, in id order, since the last thing it forgot.
local function told(of: Viewer, kind: string): { number }
    local ids = {}
    for _, one in of.seen do
        if one.kind == kind then table.insert(ids, one.id) end
    end
    table.sort(ids)
    return ids
end

-- Public --------------------------------------------------------------

return {
    -- The same person, twice, with a grant in between. A Player is an identity rather than a name,
    -- so somebody who reconnects is a new Instance holding nothing while every audience the old
    -- one was in still names the old one.
    Harness.case("set.returns", function()
        local of = Replica.serves(OPENS)
        stocks(of)
        local bob = Replica.joins(of, WATCHER)
        local alice = Replica.joins(of, SENDER)
        Replica.ours(of):audience(RED, { alice.player, bob.player })
        ships(of)

        Expect.equal(holding(alice), REDS)
        Expect.equal(holding(bob), REDS)
        Expect.equal(told(bob, ADDED), REDS)
        Replica.forgets(bob)

        Replica.leaves(of, alice)
        local fresh = Replica.joins(of, SENDER)
        ships(of)

        Expect.holds(fresh.player ~= alice.player, "the roster handed back the player that left")
        Expect.equal(holding(fresh), {})
        Expect.equal(told(fresh, ADDED), {})
        Expect.equal(told(fresh, REMOVED), {})
        Expect.equal(holding(bob), REDS)
        Expect.equal(told(bob, ADDED), {})
        Expect.equal(told(bob, REMOVED), {})
        Replica.forgets(bob)

        Replica.ours(of):audience(RED, { fresh.player, bob.player })
        ships(of)
        Expect.equal(holding(fresh), REDS)
        Expect.equal(told(fresh, ADDED), REDS)
        Expect.equal(holding(bob), REDS)
        Expect.equal(told(bob, ADDED), {})
    end),

    -- Two keys in one run, one arriving and one moving. A slot is a number inside a partition, so
    -- the same number names a record in each, and a receiver holds every record of both.
    Harness.case("set.partitions-are-shadowed-apart", function()
        local of = Replica.open(OPENS, SENDER)
        local set = Replica.ours(of)
        set:audience(RED, { of.player })
        set:audience(BLUE, { of.player })

        -- Drained, so what follows is a record moving rather than one still on its way over.
        set:add(BLUES[1], teamed(BLUE))
        ships(of)
        local held = of.viewers[1].set
        Expect.equal(held:get(BLUES[1])[HP], START)

        -- The first record on red, and the record on blue moving, inside the one flush.
        set:add(REDS[1], teamed(RED))
        set:update(BLUES[1], { [HP] = MOVED })
        ships(of)
        Expect.holds(held:get(REDS[1]) ~= nil, "a record arriving on one key reached nobody")
        Expect.equal(held:get(BLUES[1])[HP], MOVED)
    end),

    -- A key handed to one machine, then to everybody, then to another one. Widening reaches the
    -- machines that were never named and narrowing takes it back off them.
    Harness.case("set.a-key-widens-and-narrows", function()
        local of = Replica.open(OPENS, SENDER)
        local bob = Replica.joins(of, WATCHER)
        local set = Replica.ours(of)
        for _, id in REDS do
            set:add(id, teamed(RED))
        end
        set:audience(RED, { of.player })
        ships(of)

        local alice = of.viewers[1]
        Expect.equal(told(alice, ADDED), REDS)
        Expect.equal(told(bob, ADDED), {})

        -- Named everybody, which reaches the machine that was never one of its holders.
        set:audience(RED, Recipients.ALL)
        ships(of)
        Expect.equal(told(bob, ADDED), REDS)

        -- A machine arriving after the key was named everybody: a list is who was named when it
        -- was written, and everybody is whoever is here when the flush goes out.
        local late = Replica.joins(of, LATE)
        ships(of)
        Expect.equal(told(late, ADDED), REDS)

        -- Named one machine again, which takes it back off the ones no longer named.
        set:audience(RED, { bob.player })
        ships(of)
        Expect.equal(told(alice, REMOVED), REDS)
        Expect.equal(told(bob, REMOVED), {})
    end),
}
