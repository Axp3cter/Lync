--!strict
--!optimize 2
-- A set on the machine that owns it: what it refuses, and what it hands back.

local Lync = require ("@src")
local Protocol = require ("@src/wire/Protocol")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

const NAMESPACE = "sets"

--[[
    The first whole number an id cannot be. Read from the protocol rather than written here, because
    the ceiling an id shares with a varint has one home and a suite restating it is a suite that
    keeps passing after the wire moves.
]]
const CEILING = Protocol.EXACT

--[[
    The record every set here holds: one flag, one bounded number, one that may be absent, and one
    that may only climb.
]]
const RECORD = Lync.struct ({
    alive = Lync.bool (),
    score = Lync.int (0, 100),
    tag = Lync.optional (Lync.str (0, 8)),
    rank = Lync.int (0, 100):monotonic (),
})

-- Where the marked field starts, the one step above it, and a value below it.
const CLIMB = 50
const HIGHER = 51
const FALL = 20

-- A score past the bound its field declares, which is a record no flush can put on the wire.
const BEYOND = 500

--[[
    One id per check. A set is shared between the checks below, so a check reusing another's id
    would be a check whose answer depends on which of them ran first, and a module read top to
    bottom should not have an order nobody wrote down.
]]
const IDS = table.freeze ({
    live = 1,
    negative = -2,
    unknown = 4,
    required = 5,
    absent = 6,
    read = 7,
    borrowed = 8,
    missing = 9,
    climbed = 10,
    strayed = 11,
})

-- Ids no record may be added under, and the reason each one is not a number an id can take.
const REFUSED = table.freeze ({
    table.freeze ({ of = "a fraction", id = 1.5 }),
    table.freeze ({ of = "the ceiling", id = CEILING }),
    table.freeze ({ of = "the floor", id = -CEILING }),
    table.freeze ({ of = "not a number at all", id = 0 / 0 }),
})

-- How many records the walked set holds, which is more than one and few enough to read.
const WALKED = 3

--[[
    A record whose climbing field may also be cleared, which `RECORD` has no room for: its climbing
    field is required, and the two markers only meet where one field carries both.
]]
const CLIMBS = Lync.struct ({
    held = Lync.bool (),
    mark = Lync.optional (Lync.int (0, 100)):monotonic (),
})

--[[
    A walked set apart from the rest. Every check but the walk leaves a record behind, and a walk
    over a set the others had been adding to would be a walk whose answer grew every time a check
    was added above it. The third holds the one field pairing climbing with being clearable.
]]
const DEFINITIONS = {
    roster = Lync.replicate (RECORD),
    walked = Lync.replicate (RECORD),
    climbing = Lync.replicate (CLIMBS),
}

-- Private -------------------------------------------------------------

-- A record the surface is handed, fresh each time so no two calls share a table.
local function record (score: number, tag: string?): any
    return { alive = true, score = score, tag = tag, rank = CLIMB }
end

-- A check's mutations, shipped before the next one runs.
local function settled (run: () -> ())
    local ok, thrown = pcall (run)
    Lync.flush (NAMESPACE)

    if not ok then error (thrown, 0) end
end

-- Public --------------------------------------------------------------

return {
    Harness.opens (NAMESPACE, DEFINITIONS),

    --[[
        An id that is already live. The two mistakes a caller makes with one are adding over a
        record that exists and changing one that does not, and both throw: keying by
        `player.UserId` and adding twice is a bug in a join path that an overwrite would hide.
    ]]
    Harness.case ("set.add-live-id", function ()
        settled (function ()
            DEFINITIONS.roster:add (IDS.live, record (10))
            Expect.throws (
                function () DEFINITIONS.roster:add (IDS.live, record (20)) end,
                "already holds record"
            )
        end)
    end),

    --[[
        Ids that are not ids. A record id rides the wire as a whole number exact to the same ceiling
        every varint stops at, so a fraction cannot be carried, the ceiling itself cannot, and a NaN
        is neither whole nor comparable to the bound that would have refused it.
    ]]
    Harness.case ("set.add-bad-id", function ()
        settled (function ()
            for _, entry in REFUSED do
                Expect.throws (
                    function () DEFINITIONS.roster:add (entry.id, record (10)) end,
                    "cannot hold record"
                )
            end
        end)
    end),

    --[[
        A negative id, which is accepted. Studio hands a test player a negative `UserId`, and
        keying records by `UserId` is the first thing anyone writes, so refusing them would refuse
        that on the first place it is tested on.
    ]]
    Harness.case ("set.add-negative-id", function ()
        settled (function ()
            DEFINITIONS.roster:add (IDS.negative, record (30))

            local held = DEFINITIONS.roster:get (IDS.negative)
            Expect.holds (held ~= nil, "a negative id was accepted and holds nothing")
            Expect.equal ((held :: any).score, 30)
        end)
    end),

    --[[
        An update to a record that is not there. The other half of the pair above, and the same
        argument: a caller updating after a leave has a bug in their teardown, and a library that
        quietly created the record would replicate a player who is gone.
    ]]
    Harness.case ("set.update-absent", function ()
        settled (function ()
            Expect.throws (
                function () DEFINITIONS.roster:update (IDS.absent, { score = 1 }) end,
                "does not hold record"
            )
        end)
    end),

    --[[
        An update naming a field the record does not declare. The Luau type refuses this for a typed
        caller, so the throw is here for the untyped ones, and what it catches is a typo rather than
        a misunderstanding: a field silently ignored is a value that never arrives and a caller
        reading the receiver for the reason.
    ]]
    Harness.case ("set.update-unknown-field", function ()
        settled (function ()
            DEFINITIONS.roster:add (IDS.unknown, record (40))

            Expect.throws (
                function () DEFINITIONS.roster:update (IDS.unknown, { nothere = 1 } :: any) end,
                "has no field named"
            )
        end)
    end),

    --[[
        The clearing sentinel on a field that only climbs. Clearing says the value is gone rather
        than that it fell, so the check holding such a field to what it already reached has to let
        the sentinel past instead of comparing it against the number underneath it.
    ]]
    Harness.case ("set.none-on-a-field-that-only-climbs", function ()
        settled (function ()
            local climbing = DEFINITIONS.climbing
            climbing:add (IDS.required, { held = true, mark = CLIMB })
            climbing:update (IDS.required, { mark = HIGHER } :: any)
            climbing:update (IDS.required, { mark = Lync.none } :: any)

            Expect.equal ((climbing:get (IDS.required) :: any).mark, nil)
        end)
    end),

    --[[
        The clearing sentinel on a field that cannot be cleared. `Lync.none` says a value is gone,
        which only an optional field has room to say, and a required one has no representation for
        absent on the wire or off it.
    ]]
    Harness.case ("set.none-on-required", function ()
        settled (function ()
            DEFINITIONS.roster:add (IDS.required, record (50, "here"))
            DEFINITIONS.roster:update (IDS.required, { tag = Lync.none } :: any)

            local held = DEFINITIONS.roster:get (IDS.required)
            Expect.equal ((held :: any).tag, nil)

            local roster = DEFINITIONS.roster
            Expect.throws (
                function () roster:update (IDS.required, { alive = Lync.none } :: any) end,
                "is not optional and cannot be cleared"
            )
        end)
    end),

    --[[
        A removal of a record that is not there. Third of the same family, and the one a caller
        reaches most: a teardown that runs twice is the ordinary shape of a bug in a leave handler.
    ]]
    Harness.case ("set.remove-absent", function ()
        settled (function ()
            Expect.throws (
                function () DEFINITIONS.roster:remove (IDS.absent) end,
                "does not hold record"
            )
        end)
    end),

    --[[
        A read of the live record, and of one that is not there. Both halves, because the absent
        answer is what a caller branches on and a library answering an empty record instead would
        turn a missing player into a player with no score.
    ]]
    Harness.case ("set.get", function ()
        settled (function ()
            DEFINITIONS.roster:add (IDS.read, record (60, "here"))

            local held = DEFINITIONS.roster:get (IDS.read)
            Expect.holds (held ~= nil, "a record just added reads as absent")
            Expect.equal ((held :: any).score, 60)
            Expect.equal ((held :: any).tag, "here")

            Expect.equal (DEFINITIONS.roster:get (IDS.missing), nil)
        end)
    end),

    --[[
        A write to the record `get` handed back, which is the set's own storage and not a copy,
        since copying every record on every read is an allocation a game pays every frame. A
        development build freezes it so the mistake raises where it is made, and a shipped one does
        not, which is what borrowed costs when nothing is watching.
    ]]
    Harness.case ("set.get-borrowed", function ()
        settled (function ()
            DEFINITIONS.roster:add (IDS.borrowed, record (70))

            local held = DEFINITIONS.roster:get (IDS.borrowed) :: any
            if __DEV__ then
                Expect.throws (function () held.score = 80 end)
                return
            end

            held.score = 80
            Expect.equal ((DEFINITIONS.roster:get (IDS.borrowed) :: any).score, 80)
        end)
    end),

    --[[
        The whole local view, walked. A set is a map a caller reads as one, so the count and the
        walk are the two ways they reach every record without holding a list of ids beside it.
    ]]
    Harness.case ("set.iterate", function ()
        settled (function ()
            for index = 1, WALKED do
                DEFINITIONS.walked:add (index, record (index * 2))
            end

            local seen, count = {}, 0
            for id, held in DEFINITIONS.walked do
                Expect.holds (seen[id] == nil, `the walk answered {id} twice`)
                seen[id] = held.score
                count += 1
            end

            Expect.equal (count, WALKED)
            Expect.equal (#DEFINITIONS.walked, WALKED)
            for index = 1, WALKED do
                Expect.equal (seen[index], index * 2)
            end
        end)
    end),

    --[[
        An audience on a set that has no keys. `audience` says who sees the records under a key, and
        a set with no `keyBy` has one audience, which is everybody. A call naming a key there is a
        caller who thinks their set is partitioned, and the records they meant to hide are already
        everywhere.
    ]]
    Harness.case ("key.audience-unkeyed", function ()
        settled (function ()
            Expect.throws (
                function () DEFINITIONS.roster:audience ("red", Lync.all) end,
                "audience is for a set split by keyBy"
            )
        end)
    end),

    --[[
        A key declared after the seal. `keyBy` decides how a set partitions, which decides what
        every client holds and what every frame carries, and a schema that could be repartitioned
        after `start` would be a schema the two machines had already agreed on and one of them
        changed.
    ]]
    Harness.case ("key.keyby-after-start", function ()
        settled (function ()
            Expect.throws (
                function () DEFINITIONS.roster:keyBy ("score") end,
                "a declaration is not a setting"
            )
        end)
    end),

    --[[
        A field marked `:monotonic()`, written downward. The wire spends the promise, so the value
        travels as the step since the last one and a write the other way either encodes as a step
        the field cannot hold or folds into an enormous climb.
    ]]
    Harness.case ("codec.monotonic-decrease", function ()
        settled (function ()
            DEFINITIONS.roster:add (IDS.climbed, record (10))
            DEFINITIONS.roster:update (IDS.climbed, { rank = HIGHER })
            DEFINITIONS.roster:update (IDS.climbed, { rank = HIGHER })

            Expect.throws (
                function () DEFINITIONS.roster:update (IDS.climbed, { rank = FALL }) end,
                "only climbs"
            )

            local held = DEFINITIONS.roster:get (IDS.climbed)
            Expect.holds (held ~= nil, "the record the marked field belongs to is not held")
            Expect.equal ((held :: any).rank, HIGHER)
        end)
    end),

    --[[
        A field carrying a value its own bound does not, refused at the flush. The pair above looks
        like one rule answered twice and is not: a marker is a promise only the call that broke it
        knows about, and a bound belongs to the codec, which for a set is reached at the flush.
    ]]
    Harness.case ("set.field-off-grid", function ()
        settled (function ()
            DEFINITIONS.roster:add (IDS.strayed, record (BEYOND))

            local ok, thrown = pcall (function () Lync.flush (NAMESPACE) end)
            DEFINITIONS.roster:remove (IDS.strayed)

            Expect.holds (not ok, "a record no field of it can encode flushed")

            local said = tostring (thrown)
            Expect.holds (
                string.find (said, "score", 1, true) ~= nil,
                `the refusal did not name the field that carried it: {said}`
            )
        end)
    end),
}
