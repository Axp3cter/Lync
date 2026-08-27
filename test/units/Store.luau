--!strict
-- One partition's own bookkeeping: which slot holds which record, and how far the slots reach.

local Compile = require ("@src/shape/Compile")
local Lync = require ("@src")
local Store = require ("@src/state/Store")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

const SPACE = "store"
const SET = "roster"
const FIELD = "score"

--[[
    Slots a keyframe names and the records at them. The highest is neither first nor last, since
    what the store has to carry is the furthest of them and not whichever it was told about last.
]]
const SLOTS = table.freeze ({ 2, 9, 5 })
const IDS = table.freeze ({ 11, 12, 13 })
const REACH = 9

-- Private -------------------------------------------------------------

-- One store, empty, holding nothing and reaching nowhere until it is told about a record.
local function stocked (): Store.Store
    local of = { [SET] = Lync.replicate (Lync.struct ({ [FIELD] = Lync.int (0, 100) })) }
    return Store.new (Compile.build (SPACE, of :: any).byName[SET] :: any)
end

-- Public --------------------------------------------------------------

return {
    --[[
        How far the slots reach once a keyframe has stated them. A store hands out its next slot
        from this, so one told about a slot above where it had got to would otherwise hand that
        same slot out again to a record of its own.
    ]]
    Harness.case ("store.holding-reaches-the-furthest-slot", function ()
        local store = stocked ()
        Store.holds (store, IDS, SLOTS, #SLOTS)

        Expect.equal (store.high, REACH)
        Expect.equal (store.count, #SLOTS)
    end),

    --[[
        The same slots stated twice over, which a keyframe does whenever a receiver is caught up
        on records it already holds. What it holds is the same count and the same reach, neither
        of them counted again.
    ]]
    Harness.case ("store.holding-again-holds-no-more", function ()
        local store = stocked ()
        Store.holds (store, IDS, SLOTS, #SLOTS)
        Store.holds (store, IDS, SLOTS, #SLOTS)

        Expect.equal (store.high, REACH)
        Expect.equal (store.count, #SLOTS)
    end),
}
