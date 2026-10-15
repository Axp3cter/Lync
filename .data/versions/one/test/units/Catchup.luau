--!strict
--!optimize 2
-- What each client is still owed of a set it has only just met: a backlog per client and per key,
-- paid out in keyframe chunks that fit the room a flush hands over.

local Catchup = require("@src/state/Catchup")
local Codecs = require("@src/codec")
local Compile = require("@src/shape/Compile")
local Protocol = require("@src/wire/Protocol")
local Sections = require("@src/state/Sections")
local Store = require("@src/state/Store")
local Types = require("@src/Types")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local KEY = "red"
local OTHER = "blue"
local HELD = 3
local ROOM = 512
local CTX: Types.ValidateContext = table.freeze({ player = nil, now = 0, last = nil })
local AT = table.freeze({ file = "Game.Net", line = 1 })

local function compiled(): any
    local set = { kind = "set", of = Codecs.struct({ score = Codecs.int(0, 100) }), at = AT }
    return Compile.build("catchup", { roster = set :: any }).byName.roster
end

-- One store holding a few records, each scoring its own id.
local function stocked(def: any, count: number?): Store.Store
    local of = Store.new(def)
    for id = 1, count or HELD do
        local slot = Store.bind(of, id)
        of.writers[1](slot, id, id)
    end
    return of
end

local function owing(of: Catchup.Catchup, who: Player, key: any): any
    local owed = of.owed[who]
    return if owed == nil then nil else owed[key]
end

local function pair(): (Player, Player)
    local roster = Doubles.roster()
    return roster:join("one"), roster:join("two")
end

return {
    -- Two clients meeting one key are each owed the records the store holds under a backlog of
    -- their own, and a key nobody was owed or an empty store owes nothing.
    Harness.case("catchup.gained", function()
        local def = compiled()
        local of = Catchup.new()
        local store = stocked(def)
        local one, two = pair()
        Expect.equal(of.any, 0)
        Catchup.gained(of, KEY, { one, two }, store)
        Expect.equal(of.any, 2)
        Expect.equal(owing(of, one, KEY).count, HELD)
        Expect.equal(owing(of, two, KEY).count, HELD)
        Expect.holds(owing(of, one, KEY) ~= owing(of, two, KEY), "two clients shared a backlog")

        Catchup.gained(of, KEY, { one }, store)
        Expect.equal(of.any, 2)
        Catchup.gained(of, OTHER, {}, store)
        Catchup.gained(of, OTHER, { one }, Store.new(def))
        Expect.equal(of.any, 2)
    end),

    -- A lost key finishes what it owed that client and puts the client away once it is owed
    -- nothing, a cleared key finishes every client's backlog of it, and a dropped client takes
    -- only its own.
    Harness.case("catchup.finished", function()
        local def = compiled()
        local one, two = pair()

        local lost = Catchup.new()
        local store = stocked(def)
        Catchup.gained(lost, KEY, { one, two }, store)
        Catchup.gained(lost, OTHER, { one }, store)
        Expect.equal(lost.any, 3)
        Catchup.lost(lost, KEY, { one })
        Expect.equal(lost.any, 2)
        Expect.equal(owing(lost, one, KEY), nil)
        Expect.holds(owing(lost, one, OTHER) ~= nil, "a key nobody took away was taken away")
        Expect.holds(owing(lost, two, KEY) ~= nil, "one client losing a key lost it for another")
        Catchup.lost(lost, OTHER, { one })
        Expect.equal(lost.owed[one], nil)

        local cleared = Catchup.new()
        Catchup.gained(cleared, KEY, { one, two }, store)
        Catchup.gained(cleared, OTHER, { one }, store)
        Catchup.cleared(cleared, KEY)
        Expect.equal(cleared.any, 1)
        Expect.equal(owing(cleared, two, KEY), nil)
        Expect.holds(owing(cleared, one, OTHER) ~= nil, "clearing one key cleared another")

        local dropped = Catchup.new()
        Catchup.gained(dropped, KEY, { one, two }, store)
        Catchup.gained(dropped, OTHER, { one }, store)
        Catchup.dropped(dropped, one)
        Expect.equal(dropped.any, 1)
        Expect.equal(dropped.owed[one], nil)
        Expect.holds(owing(dropped, two, KEY) ~= nil, "one client leaving took another's backlog")
    end),

    -- Slots a shared section carried come off every backlog owed them, finishing one that has
    -- nothing left.
    Harness.case("catchup.retired", function()
        local def = compiled()
        local of = Catchup.new()
        local one, two = pair()
        Catchup.gained(of, KEY, { one, two }, stocked(def))
        Catchup.retired(of, KEY, { 9, 1, 2 }, 2, 2)
        Expect.equal(owing(of, one, KEY).count, 1)
        Expect.equal(owing(of, two, KEY).count, 1)
        Catchup.retired(of, OTHER, { 3 }, 1, 1)
        Expect.equal(owing(of, one, KEY).count, 1)
        Catchup.retired(of, KEY, { 3 }, 1, 1)
        Expect.equal(of.any, 0)
        Expect.equal(next(of.owed), nil)
    end),

    -- A backlog is paid out in keyframes of as many records as the room fits, in slot order,
    -- skipping a record removed since the grant, until nothing is owed.
    Harness.case("catchup.next", function()
        local def = compiled()
        local layout = Sections.of(def)
        local of = Catchup.new()
        local store = stocked(def, 5)
        local one = pair()
        Catchup.gained(of, KEY, { one }, store)
        Store.unbind(store, 3)

        local room = layout.opening + 2 * layout.entry
        Expect.equal(Catchup.reserve({ layout }), layout.opening + layout.entry)
        local b = buffer.create(ROOM)
        local reader = Sections.of(def)
        local chunks = {}
        for _ = 1, 4 do
            local after = Catchup.next(of, layout, store, one, KEY, b, 0, room)
            if after == 0 then break end
            local kind = Sections.taken(reader, b, 0, store.prev, CTX)
            Expect.equal(kind, Protocol.SECTION_KEYFRAME)
            local got = {}
            for index = 1, reader.frame.count do
                got[index] = reader.frame.ids[index]
                Expect.equal(reader.frame.values[1][index], reader.frame.ids[index])
            end
            table.insert(chunks, got)
        end
        Expect.equal(chunks, { { 1, 2 }, { 4, 5 } })
        Expect.equal(of.any, 0)
        Expect.equal(Catchup.next(of, layout, store, one, KEY, b, 0, room), 0)
    end),
}
