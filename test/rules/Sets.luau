--!strict
--!optimize 2
-- A set on the machine that owns it: what it refuses, and what it hands back.

local Codecs = require("@src/codec")
local Define = require("@src/api/Define")
local Protocol = require("@src/wire/Protocol")
local Recipients = require("@src/channel/Recipients")
local Session = require("@src/runtime/Session")
local Set = require("@src/api/Set")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local NAMESPACE = "sets"

-- The first whole number an id cannot be, read from the protocol since the ceiling an id shares
-- with a varint has one home.
local CEILING = Protocol.EXACT

-- A score past the bound its field declares, which is a record no flush can put on the wire.
local BEYOND = 500

-- One id per check, since the set is shared between them and a module read top to bottom should
-- not have an order nobody wrote down.
local IDS = table.freeze({
    live = 1,
    negative = -2,
    unknown = 4,
    required = 5,
    absent = 6,
    read = 7,
    borrowed = 8,
    missing = 9,
    strayed = 11,
})

-- Ids no record may be added under, and the reason each one is not a number an id can take.
local REFUSED = table.freeze({
    { of = "a fraction", id = 1.5 },
    { of = "the ceiling", id = CEILING },
    { of = "the floor", id = -CEILING },
    { of = "not a number at all", id = 0 / 0 },
})

-- How many records the walked set holds, which is more than one and few enough to read.
local WALKED = 3

-- The record every set here holds: one flag, one bounded number, and one that may be absent.
local RECORD = Codecs.struct({
    alive = Codecs.bool(),
    score = Codecs.int(0, 100),
    tag = Codecs.optional(Codecs.str(0, 8)),
})

-- A walked set apart from the rest, since every other check leaves a record behind.
local DEFINITIONS = Define.define(NAMESPACE, {
    roster = Set.new(RECORD),
    walked = Set.new(RECORD),
})

-- Private -------------------------------------------------------------

-- The server this namespace runs on, started once for the file over a lane nobody else is on.
local server =
    Session.new(NAMESPACE, DEFINITIONS, Doubles.wire():server(), Doubles.roster(), "server")
server:start()

local roster: any = DEFINITIONS.roster
local walked: any = DEFINITIONS.walked

-- A record the surface is handed, fresh each time so no two calls share a table.
local function record(score: number, tag: string?): any
    return { alive = true, score = score, tag = tag }
end

-- A check's mutations, shipped before the next one runs.
local function settled(run: () -> ())
    local ok, thrown = pcall(run)
    server:flush()
    if not ok then error(thrown, 0) end
end

-- Public --------------------------------------------------------------

return {
    -- An id that is already live: adding twice is a bug in a join path that an overwrite would
    -- hide.
    Harness.case("set.add-live-id", function()
        settled(function()
            roster:add(IDS.live, record(10))
            Expect.throws(function()
                roster:add(IDS.live, record(20))
            end, "already holds record")
        end)
    end),

    -- Ids that are not ids: a fraction cannot be carried, the ceiling itself cannot, and a NaN is
    -- neither whole nor comparable to the bound that would have refused it.
    Harness.case("set.add-bad-id", function()
        settled(function()
            for _, entry in REFUSED do
                Expect.throws(function()
                    roster:add(entry.id, record(10))
                end, "cannot hold record")
            end
        end)
    end),

    -- A negative id, which is accepted, since Studio hands a test player a negative UserId.
    Harness.case("set.add-negative-id", function()
        settled(function()
            roster:add(IDS.negative, record(30))
            local held = roster:get(IDS.negative)
            Expect.holds(held ~= nil, "a negative id was accepted and holds nothing")
            Expect.equal(held.score, 30)
        end)
    end),

    -- An update to a record that is not there: a library that quietly created the record would
    -- replicate a player who is gone.
    Harness.case("set.update-absent", function()
        settled(function()
            Expect.throws(function()
                roster:update(IDS.absent, { score = 1 })
            end, "does not hold record")
        end)
    end),

    -- An update naming a field the record does not declare, which catches a typo for the untyped
    -- caller.
    Harness.case("set.update-unknown-field", function()
        settled(function()
            roster:add(IDS.unknown, record(40))
            Expect.throws(function()
                roster:update(IDS.unknown, { nothere = 1 })
            end, "has no field named")
        end)
    end),

    -- The clearing sentinel on an optional field and on one that is not: a required field has no
    -- representation for absent on the wire or off it.
    Harness.case("set.none-on-required", function()
        settled(function()
            roster:add(IDS.required, record(50, "here"))
            roster:update(IDS.required, { tag = Set.NONE })
            Expect.equal(roster:get(IDS.required).tag, nil)
            Expect.throws(function()
                roster:update(IDS.required, { alive = Set.NONE })
            end, "is not optional and cannot be cleared")
        end)
    end),

    -- A removal of a record that is not there, which is a teardown that ran twice.
    Harness.case("set.remove-absent", function()
        settled(function()
            Expect.throws(function()
                roster:remove(IDS.absent)
            end, "does not hold record")
        end)
    end),

    -- A read of the live record, and of one that is not there.
    Harness.case("set.get", function()
        settled(function()
            roster:add(IDS.read, record(60, "here"))
            local held = roster:get(IDS.read)
            Expect.holds(held ~= nil, "a record just added reads as absent")
            Expect.equal(held.score, 60)
            Expect.equal(held.tag, "here")
            Expect.equal(roster:get(IDS.missing), nil)
        end)
    end),

    -- A write to the record `get` handed back, which is the set's own storage and not a copy,
    -- since copying every record on every read is an allocation a game pays every frame.
    Harness.case("set.get-borrowed", function()
        settled(function()
            roster:add(IDS.borrowed, record(70))
            local held = roster:get(IDS.borrowed)
            held.score = 80
            Expect.equal(roster:get(IDS.borrowed).score, 80)
        end)
    end),

    -- The whole local view, walked: the count and the walk are the two ways a caller reaches every
    -- record without holding a list of ids beside it.
    Harness.case("set.iterate", function()
        settled(function()
            for index = 1, WALKED do
                walked:add(index, record(index * 2))
            end
            local seen, count = {}, 0
            for id, held in walked do
                Expect.holds(seen[id] == nil, `the walk answered {id} twice`)
                seen[id] = held.score
                count += 1
            end
            Expect.equal(count, WALKED)
            Expect.equal(#walked, WALKED)
            Expect.equal(walked:size(), WALKED)
            for index = 1, WALKED do
                Expect.equal(seen[index], index * 2)
            end
        end)
    end),

    -- An audience on a set that has no keys, whose one audience is everybody already.
    Harness.case("key.audience-unkeyed", function()
        settled(function()
            Expect.throws(function()
                roster:audience("red", Recipients.ALL)
            end, "audience is for a set split by keyBy")
        end)
    end),

    -- A key declared after the seal, which would repartition a schema two machines already agreed
    -- on.
    Harness.case("key.keyby-after-start", function()
        settled(function()
            Expect.throws(function()
                roster:keyBy("score")
            end, "a declaration is not a setting")
        end)
    end),

    -- A field carrying a value its own bound does not, refused at the flush, since a bound belongs
    -- to the codec and a set reaches its codec at the flush.
    Harness.case("set.field-off-grid", function()
        settled(function()
            roster:add(IDS.strayed, record(BEYOND))
            local ok, thrown = pcall(function()
                server:flush()
            end)
            roster:remove(IDS.strayed)
            Expect.holds(not ok, "a record no field of it can encode flushed")

            local said = tostring(thrown)
            Expect.holds(
                string.find(said, "score", 1, true) ~= nil,
                `the refusal did not name the field that carried it: {said}`
            )
        end)
    end),
}
