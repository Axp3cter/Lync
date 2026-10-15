--!strict
--!optimize 2
-- What a run of mutations folds to, asked one net effect and one field selection at a time.

local Coalesce = require("@src/state/Coalesce")
local Protocol = require("@src/wire/Protocol")
local Wide = require("@src/kernel/Wide")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")

-- What an entry with nothing pending is called in the tables below, since a literal holds no nil.
local NOTHING = "none"

-- Every merge the module makes, one row for each pair a flush reaches.
local MERGES = table.freeze({
    { was = NOTHING, took = "add", is = "add" },
    { was = NOTHING, took = "update", is = "update" },
    { was = NOTHING, took = "remove", is = "remove" },
    { was = "add", took = "update", is = "add" },
    { was = "add", took = "remove", is = NOTHING },
    { was = "update", took = "update", is = "update" },
    { was = "update", took = "remove", is = "remove" },
    { was = "remove", took = "add", is = "replace" },
    { was = "replace", took = "update", is = "replace" },
    { was = "replace", took = "remove", is = "remove" },
})

-- What each pending state says about the record, as the mutations it can still take.
local AFTER = table.freeze({
    [NOTHING] = { "add", "update", "remove" },
    add = { "update", "remove" },
    update = { "update", "remove" },
    remove = { "add" },
    replace = { "update", "remove" },
})

local TAKEN = table.freeze({ "add", "update", "remove" })
local FIELDS = Protocol.MAX_FIELDS
local MOST = 8

type Step = { took: Coalesce.Kind, field: number? }

local function op(word: string): Coalesce.Kind?
    return if word == NOTHING then nil else word :: Coalesce.Kind
end

local function spelled(kind: Coalesce.Kind?): string
    return if kind == nil then NOTHING else kind
end

local function held(mask: Wide.Word): { [number]: boolean }
    local out = {}
    for field = 1, FIELDS do
        if Wide.btest(mask, Wide.bit(field)) then out[field] = true end
    end
    return out
end

-- A legal run of mutations on one record: where it was there before the flush the run may open
-- with an update or a remove, and where it was not the only way in is an add.
local function drawn(rng: Rng.Rng, existed: boolean): { Step }
    local live = existed
    local out: { Step } = {}
    for _ = 1, rng:int(1, MOST) do
        if not live then
            table.insert(out, { took = "add" :: Coalesce.Kind })
            live = true
        elseif not rng:bool() then
            table.insert(out, { took = "remove" :: Coalesce.Kind })
            live = false
        else
            table.insert(out, { took = "update" :: Coalesce.Kind, field = rng:int(1, FIELDS) })
        end
    end
    return out
end

-- The net effect by replaying a run: whether a receiver holds the record when the flush closes,
-- and whether the one it holds is the one it had.
local function netted(existed: boolean, steps: { Step }): Coalesce.Kind?
    local live, dropped = existed, false
    for _, step in steps do
        if step.took == "remove" then
            live, dropped = false, true
        else
            live = true
        end
    end
    if not live then return if existed then "remove" else nil end
    if not existed then return "add" end
    return if dropped then "replace" else "update"
end

return {
    Harness.case("coalesce.table", function()
        for _, row in MERGES do
            local got = spelled(Coalesce.merge(op(row.was), op(row.took) :: Coalesce.Kind))
            Expect.holds(got == row.is, `{row.was} then {row.took} is {got} and not {row.is}`)
        end
    end),

    -- Every pair of a pending state and a mutation is either a row above or a call the surface
    -- throws on, with none in both and none in neither.
    Harness.case("coalesce.reaches", function()
        local stated = {}
        for _, row in MERGES do
            local key = `{row.was} {row.took}`
            Expect.holds(stated[key] == nil, `{key} is stated twice`)
            stated[key] = true
        end
        local legal = {}
        for was, allowed in pairs(AFTER) do
            for _, took in allowed do
                legal[`{was} {took}`] = true
            end
        end
        Expect.equal(stated, legal)

        local taking = {}
        for _, took in TAKEN do
            taking[took] = true
        end
        for _, row in MERGES do
            Expect.holds(taking[row.took] ~= nil, `{row.took} is not a mutation a flush performs`)
            Expect.holds(AFTER[row.is] ~= nil, `{row.is} is answered and nothing takes it`)
        end
    end),

    -- Field one is the lowest bit and the widest is the highest, and the pair either side of
    -- thirty-two is the line a thirty-two bit word would lose.
    Harness.case("coalesce.mask", function()
        local none = Wide.NONE
        Expect.equal(Wide.toHex(Coalesce.touched(none, 1)), "0000000000000001")
        Expect.equal(Wide.toHex(Coalesce.touched(none, 2)), "0000000000000002")
        Expect.equal(Wide.toHex(Coalesce.touched(none, 32)), "0000000080000000")
        Expect.equal(Wide.toHex(Coalesce.touched(none, 33)), "0000000100000000")
        Expect.equal(Wide.toHex(Coalesce.touched(none, FIELDS)), "8000000000000000")

        local once = Coalesce.touched(none, 7)
        Expect.equal(Wide.toHex(Coalesce.touched(once, 7)), Wide.toHex(once))

        local up, down = none, none
        for field = 1, FIELDS do
            up = Coalesce.touched(up, field)
            down = Coalesce.touched(down, FIELDS + 1 - field)
        end
        Expect.equal(Wide.toHex(up), "FFFFFFFFFFFFFFFF")
        Expect.equal(Wide.toHex(down), Wide.toHex(up))
    end),

    -- Whether a flush moved the record between partitions, which is the one question a mask is
    -- asked that is not about what to send.
    Harness.case("coalesce.migrates", function()
        local none = Wide.NONE
        local key = 5
        Expect.equal(Coalesce.migrates(none, key), false)
        Expect.equal(Coalesce.migrates(Coalesce.touched(none, key), key), true)
        Expect.equal(Coalesce.migrates(Coalesce.touched(none, key + 1), key), false)

        local top = Coalesce.touched(none, FIELDS)
        Expect.equal(Coalesce.migrates(top, FIELDS), true)
        Expect.equal(Coalesce.migrates(top, 1), false)

        local every = none
        for field = 1, FIELDS do
            every = Coalesce.touched(every, field)
        end
        Expect.equal(Coalesce.migrates(every, nil), false)
        Expect.equal(Coalesce.migrates(none, nil), false)
    end),

    -- Any run folded through the merge, against the same run replayed: a table can answer every
    -- pair and still lose a removal three mutations back.
    Harness.property("coalesce.nets", "leaves", function(rng: Rng.Rng)
        local existed = rng:bool()
        local steps = drawn(rng, existed)
        local pending: Coalesce.Kind? = nil
        local mask = Wide.NONE
        local named = {}
        for _, step in steps do
            pending = Coalesce.merge(pending, step.took)
            if step.field == nil then continue end
            mask = Coalesce.touched(mask, step.field)
            named[step.field] = true
        end
        Expect.equal(spelled(pending), spelled(netted(existed, steps)))
        Expect.equal(held(mask), named)
    end),
}
