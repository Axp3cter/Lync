--!strict
--!optimize 2
--[[
    What a run of mutations folds to, asked one net effect and one field selection at a time.
]]

local Coalesce = require ("@src/state/Coalesce")
local Protocol = require ("@src/wire/Protocol")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Rng = require ("@test/harness/Rng")
local Wide = require ("@src/kernel/Wide")

-- Constants -----------------------------------------------------------

--[[
    What an entry with nothing pending is called in the tables below. A merge answers nil for it,
    because a record added and removed inside one flush leaves nothing to say, and an op meaning
    nothing would be a fifth kind the wire has no section for. A table literal cannot hold a nil, so
    the absence is spelled here and turned back at the one place these rows are read.
]]
const NOTHING = "none"

--[[
    Every merge the protocol states, in the order it states them. `replace` is written in prose
    rather than as a word, being the one row that names two sections instead of one.
]]
const MERGES = table.freeze ({
    table.freeze ({ was = NOTHING, took = "add", is = "add" }),
    table.freeze ({ was = NOTHING, took = "update", is = "update" }),
    table.freeze ({ was = NOTHING, took = "remove", is = "remove" }),
    table.freeze ({ was = "add", took = "update", is = "add" }),
    table.freeze ({ was = "add", took = "remove", is = NOTHING }),
    table.freeze ({ was = "update", took = "update", is = "update" }),
    table.freeze ({ was = "update", took = "remove", is = "remove" }),
    table.freeze ({ was = "remove", took = "add", is = "replace" }),
    table.freeze ({ was = "replace", took = "update", is = "replace" }),
    table.freeze ({ was = "replace", took = "remove", is = "remove" }),
})

--[[
    What each pending state says about the record, as the mutations it can still take. An entry
    holding something says whether the record is live, and an entry holding nothing says nothing at
    all, because a flush opens both on a record that was already there and on one that was not.
]]
const AFTER = table.freeze ({
    [NOTHING] = table.freeze ({ "add", "update", "remove" }),
    add = table.freeze ({ "update", "remove" }),
    update = table.freeze ({ "update", "remove" }),
    remove = table.freeze ({ "add" }),
    replace = table.freeze ({ "update", "remove" }),
})

-- Every mutation a merge can take, which is what the pairs are counted over.
const TAKEN = table.freeze ({ "add", "update", "remove" })

-- Fields a record may hold, which is the width of the mask that names them.
const FIELDS = Protocol.MAX_FIELDS

-- Mutations a drawn flush performs on one record.
const MOST = 8

-- Types ---------------------------------------------------------------

-- One mutation as a flush performs it, carrying the field where it named one.
type Step = { took: Coalesce.Kind, field: number? }

-- Private -------------------------------------------------------------

-- A row's word as a merge takes it, where nothing pending is a nil.
local function op (word: string): Coalesce.Kind?
    if word == NOTHING then return nil end
    return word :: Coalesce.Kind
end

-- The word a merge answered, so a row and an answer compare as the same thing.
local function spelled (kind: Coalesce.Kind?): string
    if kind == nil then return NOTHING end
    return kind
end

-- Every field a mask holds, read back one bit at a time.
local function held (mask: Wide.Word): { [number]: boolean }
    local out = {}
    for field = 1, FIELDS do
        if Wide.meets (mask, Wide.bit (field)) then out[field] = true end
    end
    return out
end

--[[
    A legal run of mutations on one record. What is legal turns on whether the record is live,
    because the surface throws on everything else, so drawing only the legal ones is what makes
    every run here one a flush can produce. Where the record was there before the flush opened the
    run can start with an update or a remove, and where it was not the only way in is an add.
]]
local function drawn (rng: Rng.Rng, existed: boolean): { Step }
    local live = existed
    local out: { Step } = {}

    for _ = 1, Rng.int (rng, 1, MOST) do
        if not live then
            table.insert (out, { took = "add" :: Coalesce.Kind })
            live = true
            continue
        end
        if not Rng.bool (rng) then
            table.insert (out, { took = "remove" :: Coalesce.Kind })
            live = false
            continue
        end
        table.insert (out, { took = "update" :: Coalesce.Kind, field = Rng.int (rng, 1, FIELDS) })
    end
    return out
end

--[[
    The net effect worked out by replaying a run rather than by merging it. A receiver either holds
    the record when the flush opens or it does not, and the only two questions the wire answers are
    whether it holds one when the flush closes and whether the one it holds is the one it had.
]]
local function netted (existed: boolean, steps: { Step }): Coalesce.Kind?
    local live = existed
    local dropped = false

    for _, step in steps do
        if step.took ~= "remove" then
            live = true
            continue
        end
        live = false
        dropped = true
    end

    if not live then return if existed then "remove" else nil end
    if not existed then return "add" end
    return if dropped then "replace" else "update"
end

-- Public --------------------------------------------------------------

return {
    --[[
        The net-effect table, row by row. An add merged as an update ships a delta against a
        baseline nobody established, and a remove merged as one ships a change to a record that is
        gone. Both decode cleanly and leave the machines holding different sets.
    ]]
    Harness.case ("coalesce.table", function ()
        for _, row in MERGES do
            local took = op (row.took) :: Coalesce.Kind
            local got = spelled (Coalesce.merge (op (row.was), took))
            if got == row.is then continue end
            Expect.holds (false, `{row.was} then {row.took} is {got} and not {row.is}`)
        end
    end),

    --[[
        The pairs a coalescer sees are exactly the pairs the surface can hand it. Every combination
        of a pending state and a mutation is either a row above or a call the surface throws on,
        with none in both and none in neither.
    ]]
    Harness.case ("coalesce.reaches", function ()
        local stated = {}
        for _, row in MERGES do
            local key = `{row.was} {row.took}`
            Expect.holds (stated[key] == nil, `{key} is stated twice`)
            stated[key] = true
        end

        local legal = {}
        for was, allowed in pairs (AFTER) do
            for _, took in allowed do
                legal[`{was} {took}`] = true
            end
        end

        for key in stated do
            if legal[key] ~= nil then continue end
            Expect.holds (false, `{key} is a row the surface cannot reach`)
        end
        for key in legal do
            if stated[key] ~= nil then continue end
            Expect.holds (false, `{key} is reachable and no row answers it`)
        end

        local taking = {}
        for _, took in TAKEN do
            taking[took] = true
        end
        for _, row in MERGES do
            if taking[row.took] == nil then
                Expect.holds (false, `{row.took} is not a mutation a flush performs`)
            end
            if AFTER[row.is] ~= nil then continue end
            Expect.holds (false, `{row.was} then {row.took} answers {row.is}, which nothing takes`)
        end
    end),

    --[[
        Where a field sits in the mask. Field one is the lowest bit and the widest is the highest,
        and the pair either side of thirty-two is the line that matters: a mask kept in a thirty-two
        bit word answers every field below it and loses every field above.
    ]]
    Harness.case ("coalesce.mask", function ()
        local none = Wide.NONE

        Expect.equal (Wide.text (Coalesce.touched (none, 1)), "0000000000000001")
        Expect.equal (Wide.text (Coalesce.touched (none, 2)), "0000000000000002")
        Expect.equal (Wide.text (Coalesce.touched (none, 32)), "0000000080000000")
        Expect.equal (Wide.text (Coalesce.touched (none, 33)), "0000000100000000")
        Expect.equal (Wide.text (Coalesce.touched (none, FIELDS)), "8000000000000000")

        local once = Coalesce.touched (none, 7)
        Expect.equal (Wide.text (Coalesce.touched (once, 7)), Wide.text (once))

        local up, down = none, none
        for field = 1, FIELDS do
            up = Coalesce.touched (up, field)
            down = Coalesce.touched (down, FIELDS + 1 - field)
        end
        Expect.equal (Wide.text (up), "FFFFFFFFFFFFFFFF")
        Expect.equal (Wide.text (down), Wide.text (up))
    end),

    --[[
        Whether a flush moved the record between partitions, which is the one question a mask is
        asked that is not about what to send. A test missing it would ship a delta into a partition
        holding no such record.
    ]]
    Harness.case ("coalesce.migrates", function ()
        local none = Wide.NONE
        local key = 5

        Expect.equal (Coalesce.migrates (none, key), false)
        Expect.equal (Coalesce.migrates (Coalesce.touched (none, key), key), true)
        Expect.equal (Coalesce.migrates (Coalesce.touched (none, key + 1), key), false)

        local top = Coalesce.touched (none, FIELDS)
        Expect.equal (Coalesce.migrates (top, FIELDS), true)
        Expect.equal (Coalesce.migrates (top, 1), false)

        local every = none
        for field = 1, FIELDS do
            every = Coalesce.touched (every, field)
        end
        Expect.equal (Coalesce.migrates (every, nil), false)
        Expect.equal (Coalesce.migrates (none, nil), false)
    end),

    --[[
        Any run of mutations, folded through the merge and against the same run replayed. The table
        above says the merge is right about a pair and this says a fold of pairs is right about a
        flush, which is not the same claim: a table can answer every pair and still lose a removal
        three mutations back.
    ]]
    Harness.property ("coalesce.nets", "leaves", function (rng: Rng.Rng)
        local existed = Rng.bool (rng)
        local steps = drawn (rng, existed)

        local pending: Coalesce.Kind? = nil
        local mask = Wide.NONE
        local named = {}

        for _, step in steps do
            pending = Coalesce.merge (pending, step.took)
            if step.field == nil then continue end

            mask = Coalesce.touched (mask, step.field)
            named[step.field] = true
        end

        Expect.equal (spelled (pending), spelled (netted (existed, steps)))
        Expect.equal (held (mask), named)
    end),
}
