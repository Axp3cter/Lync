--!strict
--!optimize 2
-- One partition's own bookkeeping: which slot holds which record, how far the slots reach, and
-- the two views one write fills.

local Codecs = require("@src/codec")
local Compile = require("@src/shape/Compile")
local Store = require("@src/state/Store")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local AT = table.freeze({ file = "Game.Net", line = 1 })

-- Slots a keyframe names and the records at them. The highest is neither first nor last.
local SLOTS = table.freeze({ 2, 9, 5 })
local IDS = table.freeze({ 11, 12, 13 })
local REACH = 9

local function stocked(newest: boolean?): Store.Store
    local fields: any = { score = Codecs.int(0, 100), name = Codecs.str(0, 8) }
    if newest then fields.pos = Codecs.vec3():newest() end
    local set = { kind = "set", of = Codecs.struct(fields), at = AT }
    return Store.new(Compile.build("store", { roster = set :: any }).byName.roster :: any)
end

return {
    -- A keyframe stating slots leaves the store reaching the furthest of them, and stating the
    -- same slots again holds no more.
    Harness.case("store.holds", function()
        local store = stocked()
        Store.holds(store, IDS, SLOTS, #SLOTS)
        Expect.equal(store.high, REACH)
        Expect.equal(store.count, #SLOTS)
        Expect.equal(store.slotOf[12], 9)
        Expect.equal(store.ids[5], 13)
        Expect.equal(store.rows[11], { score = false, name = false })

        Store.holds(store, IDS, SLOTS, #SLOTS)
        Expect.equal(store.high, REACH)
        Expect.equal(store.count, #SLOTS)
    end),

    -- A bind takes the lowest free slot, a spared slot is handed out again, and an unbind hands
    -- the slot back and forgets the record.
    Harness.case("store.bind-and-unbind", function()
        local store = stocked()
        Expect.equal(
            { Store.bind(store, 1), Store.bind(store, 2), Store.bind(store, 3) },
            { 1, 2, 3 }
        )
        Expect.equal(store.count, 3)
        Expect.equal(store.rows[2], { score = false, name = false })

        Expect.equal(Store.unbind(store, 2), 2)
        Expect.equal(Store.unbind(store, 2), nil)
        Expect.equal(store.count, 2)
        Expect.equal(store.rows[2], nil)
        Expect.equal(store.ids[2], nil)

        Expect.equal(Store.bind(store, 4), 4)
        Store.spare(store, 2)
        Expect.equal(Store.bind(store, 5), 2)
        Expect.equal(Store.bind(store, 6), 5)
        Expect.equal(store.high, 5)
    end),

    -- One write fills both the column and the row, singly and spread over a section.
    Harness.case("store.writers-and-spreads", function()
        local store = stocked()
        local score = store.def.fieldIndex.score
        local name = store.def.fieldIndex.name
        Store.bind(store, 7)
        Store.bind(store, 8)
        store.writers[score](1, 7, 42)
        Expect.equal(store.columns[score][1], 42)
        Expect.equal(store.rows[7], { score = 42, name = false })

        store.spreads[name]({ 1, 2 }, { 7, 8 }, { "seven", "eight" }, 2)
        Expect.equal(store.columns[name], { "seven", "eight" })
        Expect.equal(store.rows[7].name, "seven")
        Expect.equal(store.rows[8].name, "eight")
    end),

    -- A baseline is kept for a grid field that is not newest, a last-sent value for a newest one,
    -- and generations only where a newest field exists, counting round when a slot is reused.
    Harness.case("store.baselines-and-generations", function()
        local plain = stocked()
        Expect.holds(plain.prev[plain.def.fieldIndex.score] ~= nil, "an int kept no baseline")
        Expect.equal(plain.prev[plain.def.fieldIndex.name], nil)
        Expect.equal(plain.gens, nil)

        local fresh = stocked(true)
        local pos = fresh.def.fieldIndex.pos
        Expect.equal(fresh.prev[pos], nil)
        Expect.holds(fresh.sent[pos] ~= nil, "a newest field kept no last value")
        local gens = fresh.gens :: { [number]: number }
        Store.bind(fresh, 1)
        Expect.equal(gens[1], 0)
        for turn = 1, 5 do
            Store.unbind(fresh, turn)
            Store.spare(fresh, 1)
            Store.bind(fresh, turn + 1)
            Expect.equal(gens[1], turn % 4)
        end
    end),

    -- Clearing empties every view and hands every slot back to the beginning.
    Harness.case("store.clear", function()
        local store = stocked(true)
        Store.bind(store, 1)
        Store.bind(store, 2)
        store.writers[1](1, 1, 5)
        Store.spare(store, 3)
        Store.clear(store)
        Expect.equal(store.count, 0)
        Expect.equal(store.high, 0)
        Expect.equal(next(store.rows), nil)
        Expect.equal(next(store.ids), nil)
        Expect.equal(next(store.columns[1]), nil)
        Expect.equal(next(store.gens :: any), nil)
        Expect.equal(Store.bind(store, 9), 1)
    end),
}
