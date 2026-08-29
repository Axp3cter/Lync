--!strict
--!optimize 2
--[[
    A record whose key field changes: which of its two partitions each viewer holds, and what each
    of them is told about one record moving between them.
]]

local Doubles = require ("@fixtures/Doubles")
local Schemas = require ("@fixtures/Schemas")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Replica = require ("@test/harness/Replica")

-- Constants -----------------------------------------------------------

const SPACE = "migration"
const ROSTER = Schemas.ROSTER

-- The keyed field and the one beside it, so a migration can be told from a plain change.
const TEAM = Schemas.TEAM
const HP = Schemas.HP

-- Two keys, and the order they are named in is the order their partitions are made in.
const RED = Schemas.RED
const BLUE = Schemas.BLUE

-- One record, and the value its unkeyed field takes before and after it moves.
const ID = 1
const START = 10
const AFTER = 20

-- Types ---------------------------------------------------------------

type Run = Replica.Alone
type Seen = Replica.Seen
type Viewer = Replica.Viewer

-- Private -------------------------------------------------------------

-- What every run here opens with: a server holding the keyed set, and nobody watching it.
const OPENS: Replica.Opening = { space = SPACE, defined = Schemas.roster, watched = ROSTER }

-- What a viewer was told, as one string, so a reading names the whole of it rather than a count.
local function told (of: Viewer): string
    local parts = {}
    for _, one in of.seen do
        table.insert (parts, `{one.kind}:{one.id}`)
    end
    return table.concat (parts, " ")
end

-- What the lane carries to one viewer from here on, as text.
local function watching (of: Run, who: Player): () -> string
    local held: { string } = {}
    of.wire:watch (function (carried: Doubles.Carried)
        if carried.to ~= who then return end

        table.insert (held, Doubles.dumped (carried))
    end)

    return function () return table.concat (held, "\n") end
end

--[[
    The stage every check here runs on: a record under one key, and three viewers between them
    holding the old key alone, the new key alone, and both.
]]
local function staged (): (Run, Viewer, Viewer, Viewer)
    local of = Replica.serves (OPENS)

    local loser = Replica.joins (of, "loser")
    local gainer = Replica.joins (of, "gainer")
    local holder = Replica.joins (of, "holder")

    Replica.ours (of):audience (RED, { loser.player, holder.player })
    Replica.ours (of):audience (BLUE, { gainer.player, holder.player })

    Replica.ours (of):add (ID, { [TEAM] = RED, [HP] = START })
    Replica.drains (of)

    Expect.equal (told (loser), `added:{ID}`)
    Expect.equal (told (gainer), "")
    Expect.equal (told (holder), `added:{ID}`)

    Replica.forgets (loser)
    Replica.forgets (gainer)
    Replica.forgets (holder)

    return of, loser, gainer, holder
end

-- Public --------------------------------------------------------------

return {
    --[[
        One record moving from the key it was under to the key it names now, which is a removal
        toward the audiences losing it, a keyframe toward those gaining it, and a plain change
        toward those holding it under both. The wire carries only the first two, so the third is
        what the receiving end makes of them.
    ]]
    Harness.case ("key.migrate-three-ways", function ()
        local of, loser, gainer, holder = staged ()

        Replica.ours (of):update (ID, { [TEAM] = BLUE, [HP] = AFTER })
        Replica.drains (of)

        Expect.equal (told (loser), `removed:{ID}`)
        Expect.equal (told (gainer), `added:{ID}`)
        Expect.equal (told (holder), `changed:{ID}`)

        local old = holder.seen[1].old
        Expect.holds (old ~= nil, "a migration read as a change carried nothing to compare against")
        Expect.equal ((old :: any)[TEAM], RED)
        Expect.equal ((old :: any)[HP], START)

        -- And every one of them holds what its audiences allow afterwards.
        Expect.equal (loser.set:get (ID), nil)
        Expect.equal ((gainer.set:get (ID) :: any)[HP], AFTER)
        Expect.equal ((holder.set:get (ID) :: any)[HP], AFTER)
    end),

    --[[
        The same record moved back, so the partition it arrives in is one the flush reaches before
        the one it leaves. A flush plans everything taking a record away before anything putting one
        down. Were it walked a partition at a time instead, a viewer of both keys would half the
        time apply the keyframe and then the removal over it, and hold nothing.
    ]]
    Harness.case ("key.migrate-order", function ()
        local of, loser, gainer, holder = staged ()

        Replica.ours (of):update (ID, { [TEAM] = BLUE })
        Replica.drains (of)
        Expect.equal (told (holder), `changed:{ID}`)

        Replica.forgets (loser)
        Replica.forgets (gainer)
        Replica.forgets (holder)

        Replica.ours (of):update (ID, { [TEAM] = RED, [HP] = AFTER })
        Replica.drains (of)

        Expect.equal (told (holder), `changed:{ID}`)
        Expect.equal (told (gainer), `removed:{ID}`)
        Expect.equal (told (loser), `added:{ID}`)

        Expect.equal ((holder.set:get (ID) :: any)[HP], AFTER)
        Expect.equal ((holder.set:get (ID) :: any)[TEAM], RED)
    end),

    --[[
        A record leaving a viewer's audience beside a record leaving existence, which are two facts
        that have to cross as the same bytes. A removal naming its reason breaks the boundary at
        the moment it matters, since a viewer told the record moved has been told it is still there
        under a key they were never meant to know of.
    ]]
    Harness.case ("key.no-cause-leak", function ()
        local moved, movedLoser = staged ()
        local sent = watching (moved, movedLoser.player)

        Replica.ours (moved):update (ID, { [TEAM] = BLUE })
        Replica.drains (moved)

        local gone, goneLoser = staged ()
        local also = watching (gone, goneLoser.player)

        Replica.ours (gone):remove (ID)
        Replica.drains (gone)

        Expect.equal (told (movedLoser), `removed:{ID}`)
        Expect.equal (told (goneLoser), `removed:{ID}`)

        Expect.holds (sent () ~= "", "a record left an audience and nothing crossed the wire")
        Expect.equal (sent (), also ())
    end),
}
