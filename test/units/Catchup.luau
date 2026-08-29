--!strict
--!optimize 2
--[[
    What each client is still owed of a set it has only just met. A backlog is per client and per
    key, since two clients meeting one key meet it at their own pace and a key taken away from one
    of them owes the others no less than it did.
]]

local Catchup = require ("@src/state/Catchup")
local Compile = require ("@src/shape/Compile")
local Lync = require ("@src")
local Store = require ("@src/state/Store")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

const SPACE = "catchup"
const SET = "roster"
const FIELD = "score"

-- The key a backlog is filed under, and a second one left standing when the first is taken away.
const KEY = "red"
const OTHER = "blue"

-- How many records the store below holds, which is what a backlog over it is owed.
const HELD = 3

-- Private -------------------------------------------------------------

-- The one set this file drives, which is a record of one field under a name a key files it by.
local function declared (): any
    return { [SET] = Lync.replicate (Lync.struct ({ [FIELD] = Lync.int (0, 100) })) }
end

-- One store holding a few records, which is what a client meeting the key is owed.
local function stocked (): Store.Store
    local of = Store.new (Compile.build (SPACE, declared ()).byName[SET] :: any)
    for id = 1, HELD do
        Store.bind (of, id)
    end
    return of
end

-- What a client is owed of a key, or nothing where it is owed none of it.
local function owing (of: Catchup.Catchup, who: Player, key: any): any
    local owed = of.owed[who]
    return if owed == nil then nil else owed[key]
end

-- Public --------------------------------------------------------------

return {
    --[[
        Two clients meeting one key. Each is owed the records the store holds, and each is owed
        them under a backlog of its own: shared, one client draining its own would drain the
        other's with it and the second would be told about records it never saw.
    ]]
    Harness.case ("catchup.two-clients-are-owed-apart", function ()
        local of = Catchup.new ()
        local store = stocked ()

        local one = Instance.new ("Player") :: any
        local two = Instance.new ("Player") :: any

        Expect.equal (of.any, 0)
        Catchup.gained (of, KEY, { one, two }, store)

        Expect.equal (of.any, 2)
        Expect.equal (owing (of, one, KEY).count, HELD)
        Expect.equal (owing (of, two, KEY).count, HELD)
        Expect.holds (owing (of, one, KEY) ~= owing (of, two, KEY), "two clients shared a backlog")
    end),

    -- A key nobody was ever owed, and a store with nothing in it, which owe nothing between them.
    Harness.case ("catchup.owes-nothing-for-nothing", function ()
        local of = Catchup.new ()
        local who = Instance.new ("Player") :: any

        Catchup.gained (of, KEY, {}, stocked ())
        Expect.equal (of.any, 0)

        local built = Compile.build (SPACE, declared ())
        Catchup.gained (of, KEY, { who }, Store.new (built.byName[SET] :: any))
        Expect.equal (of.any, 0)
    end),

    --[[
        A key taken away from one client. What it owed that client is finished with and the client
        itself is put away once it is owed nothing at all, since a client kept under an empty table
        is one every walk of the backlogs goes on visiting for as long as it is connected.
    ]]
    Harness.case ("catchup.a-lost-key-is-put-away", function ()
        local of = Catchup.new ()
        local store = stocked ()

        local one = Instance.new ("Player") :: any
        local two = Instance.new ("Player") :: any

        Catchup.gained (of, KEY, { one, two }, store)
        Catchup.gained (of, OTHER, { one }, store)
        Expect.equal (of.any, 3)

        Catchup.lost (of, KEY, { one })
        Expect.equal (of.any, 2)
        Expect.equal (owing (of, one, KEY), nil)
        Expect.holds (owing (of, one, OTHER) ~= nil, "a key nobody took away was taken away")
        Expect.holds (owing (of, two, KEY) ~= nil, "one client losing a key lost it for another")

        Catchup.lost (of, OTHER, { one })
        Expect.equal (of.owed[one], nil)
    end),

    -- A key emptied, which is every client's backlog of it and no client's backlog of another.
    Harness.case ("catchup.a-cleared-key-is-put-away", function ()
        local of = Catchup.new ()
        local store = stocked ()

        local one = Instance.new ("Player") :: any
        local two = Instance.new ("Player") :: any

        Catchup.gained (of, KEY, { one, two }, store)
        Catchup.gained (of, OTHER, { one }, store)

        Catchup.cleared (of, KEY)
        Expect.equal (of.any, 1)
        Expect.equal (owing (of, two, KEY), nil)
        Expect.holds (owing (of, one, OTHER) ~= nil, "clearing one key cleared another")
    end),

    -- A client gone, taking what it waited on and leaving what everybody else waits on.
    Harness.case ("catchup.a-dropped-client-takes-its-own", function ()
        local of = Catchup.new ()
        local store = stocked ()

        local one = Instance.new ("Player") :: any
        local two = Instance.new ("Player") :: any

        Catchup.gained (of, KEY, { one, two }, store)
        Catchup.gained (of, OTHER, { one }, store)
        Expect.equal (of.any, 3)

        Catchup.dropped (of, one)
        Expect.equal (of.any, 1)
        Expect.equal (of.owed[one], nil)
        Expect.holds (owing (of, two, KEY) ~= nil, "one client leaving took another's backlog")
    end),
}
