--!strict
--!optimize 2
-- A record whose key field changes: which of its two partitions each viewer holds, and what each
-- of them is told about one record moving between them.

local Doubles = require("@fixtures/Doubles")
local Schemas = require("@fixtures/Schemas")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Replica = require("@test/harness/Replica")

local SPACE = "migration"
local ROSTER = Schemas.ROSTER

-- The keyed field and the one beside it, so a migration can be told from a plain change.
local TEAM = Schemas.TEAM
local HP = Schemas.HP

-- Two keys, and the order they are named in is the order their partitions are made in.
local RED = Schemas.RED
local BLUE = Schemas.BLUE

-- One record, and the value its unkeyed field takes before and after it moves.
local ID = 1
local START = 10
local AFTER = 20

-- What every run here opens with: a server holding the keyed set, and nobody watching it.
local OPENS: Replica.Opening = { space = SPACE, defined = Schemas.roster, watched = ROSTER }

type Run = Replica.Alone
type Viewer = Replica.Viewer

-- The three viewers a record moving between two keys is watched by: holding the old key alone,
-- the new key alone, and both.
type Stage = { read run: Run, read loser: Viewer, read gainer: Viewer, read holder: Viewer }

-- Private -------------------------------------------------------------

-- What a viewer was told, as one string, so a reading names the whole of it rather than a count.
local function told(of: Viewer): string
    local parts = {}
    for _, one in of.seen do
        table.insert(parts, `{one.kind}:{one.id}`)
    end
    return table.concat(parts, " ")
end

-- What the lane carries to one viewer from here on, as text.
local function watching(of: Run, who: Player): () -> string
    local held: { string } = {}
    of.wire:watch(function(carried: Doubles.Carried)
        if carried.to == who then table.insert(held, Doubles.dumped(carried)) end
    end)
    return function()
        return table.concat(held, "\n")
    end
end

local function forgotten(of: Stage)
    Replica.forgets(of.loser)
    Replica.forgets(of.gainer)
    Replica.forgets(of.holder)
end

-- The stage every check here runs on: a record under one key, and the three viewers between them
-- holding the old key alone, the new key alone, and both.
local function staged(): Stage
    local run = Replica.serves(OPENS)
    local of: Stage = {
        run = run,
        loser = Replica.joins(run, "loser"),
        gainer = Replica.joins(run, "gainer"),
        holder = Replica.joins(run, "holder"),
    }
    local set = Replica.ours(run)
    set:audience(RED, { of.loser.player, of.holder.player })
    set:audience(BLUE, { of.gainer.player, of.holder.player })
    set:add(ID, { [TEAM] = RED, [HP] = START })
    Replica.drains(run)

    Expect.equal(told(of.loser), `added:{ID}`)
    Expect.equal(told(of.gainer), "")
    Expect.equal(told(of.holder), `added:{ID}`)
    forgotten(of)
    return of
end

-- Public --------------------------------------------------------------

return {
    -- One record moving from the key it was under to the key it names now: a removal toward the
    -- audiences losing it, a keyframe toward those gaining it, and a plain change toward those
    -- holding it under both, which the receiving end makes of the first two.
    Harness.case("key.migrate-three-ways", function()
        local of = staged()
        Replica.ours(of.run):update(ID, { [TEAM] = BLUE, [HP] = AFTER })
        Replica.drains(of.run)

        Expect.equal(told(of.loser), `removed:{ID}`)
        Expect.equal(told(of.gainer), `added:{ID}`)
        Expect.equal(told(of.holder), `changed:{ID}`)

        local old = of.holder.seen[1].old
        Expect.holds(old ~= nil, "a migration read as a change carried nothing to compare against")
        Expect.equal(old[TEAM], RED)
        Expect.equal(old[HP], START)

        -- And every one of them holds what its audiences allow afterwards.
        Expect.equal(of.loser.set:get(ID), nil)
        Expect.equal(of.gainer.set:get(ID)[HP], AFTER)
        Expect.equal(of.holder.set:get(ID)[HP], AFTER)
    end),

    -- The same record moved back, so the partition it arrives in is one the flush reaches before
    -- the one it leaves. A flush plans everything taking a record away before anything putting one
    -- down, or a viewer of both keys would apply the keyframe and then the removal over it.
    Harness.case("key.migrate-order", function()
        local of = staged()
        Replica.ours(of.run):update(ID, { [TEAM] = BLUE })
        Replica.drains(of.run)
        Expect.equal(told(of.holder), `changed:{ID}`)
        forgotten(of)

        Replica.ours(of.run):update(ID, { [TEAM] = RED, [HP] = AFTER })
        Replica.drains(of.run)

        Expect.equal(told(of.holder), `changed:{ID}`)
        Expect.equal(told(of.gainer), `removed:{ID}`)
        Expect.equal(told(of.loser), `added:{ID}`)
        Expect.equal(of.holder.set:get(ID)[HP], AFTER)
        Expect.equal(of.holder.set:get(ID)[TEAM], RED)
    end),

    -- A record leaving a viewer's audience beside a record leaving existence, which are two facts
    -- that have to cross as the same bytes, since a removal naming its reason would tell a viewer
    -- the record is still there under a key they were never meant to know of.
    Harness.case("key.no-cause-leak", function()
        local moved = staged()
        local sent = watching(moved.run, moved.loser.player)
        Replica.ours(moved.run):update(ID, { [TEAM] = BLUE })
        Replica.drains(moved.run)

        local gone = staged()
        local also = watching(gone.run, gone.loser.player)
        Replica.ours(gone.run):remove(ID)
        Replica.drains(gone.run)

        Expect.equal(told(moved.loser), `removed:{ID}`)
        Expect.equal(told(gone.loser), `removed:{ID}`)
        Expect.holds(sent() ~= "", "a record left an audience and nothing crossed the wire")
        Expect.equal(sent(), also())
    end),
}
