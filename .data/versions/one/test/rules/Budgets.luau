--!strict
--!optimize 2
-- A flush with a name and a number on it: which namespace it drains, and how much of that
-- namespace's state it carries.

local Codecs = require("@src/codec")
local Packet = require("@src/api/Packet")
local Protocol = require("@src/wire/Protocol")
local Set = require("@src/api/Set")

local Doubles = require("@fixtures/Doubles")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Replica = require("@test/harness/Replica")

-- Two namespaces, because every claim here is about a boundary and a boundary needs a second side.
local ARENA = "arena"
local LOBBY = "lobby"

-- The one client, since a budget is per client, and the one who arrives after the records did.
local SENDER = "alice"
local LATE = "bob"

-- One packet and one set in each namespace, and the one field a record carries, which is the
-- weight a budget is measured against.
local BEAT = "beat"
local BOARD = "board"
local TEXT = "text"

-- The bound on what a fire carries, and the width every record is padded to.
local TOP = 100
local WIDE = 128
local FILLER = "x"

-- A packet wide enough that a handful of fires outweigh what one fire may carry, since the only
-- way to the guard is a frame built out of fires nobody drained.
local HEAVY = "heavy"
local HEAVIEST = 60000

-- Records stocked before a budgeted flush, enough that the set outweighs the smallest legal budget
-- several times over.
local RECORDS = 40

-- The smallest budget a caller may pass, and one with more room than this file ever queues.
local FLOOR = Protocol.BUDGET_FLOOR
local ROOM = FLOOR * 64

-- What a fire carries, one per fire a check makes, so an arrival names the fire it came from.
local CARRIED = 7
local PASSED = 11
local OTHER = 23

-- One namespace on both machines, with what its client heard since the last reading.
type Space = {
    read wire: Doubles.Wire,
    read player: Player,
    read server: Replica.Machine,
    read client: Replica.Machine,
    read heard: { number },
}

-- The two of them, keyed by the names they were opened under.
type Pair = { [string]: Space }

-- Private -------------------------------------------------------------

-- A record's payload, distinct per id and the same width whatever the id is.
local function spelled(id: number): string
    local tail = tostring(id)
    return string.rep(FILLER, WIDE - #tail) .. tail
end

-- The definitions one machine requires, built once a side and once a namespace, since a budget is
-- spent per namespace.
local function defined(): any
    return {
        [BEAT] = Packet.new(Codecs.int(0, TOP)),
        [BOARD] = Set.new(Codecs.struct({ [TEXT] = Codecs.str(1, WIDE) })),
        [HEAVY] = Packet.new(Codecs.str(1, HEAVIEST)),
    }
end

-- One namespace: its own lane, a session either side of it, and a listener on the packet before
-- the client starts.
local function opened(space: string, roster: Doubles.Roster, player: Player): Space
    local heard: { number } = {}
    local pair = Replica.paired({
        space = space,
        defined = defined,
        label = SENDER,
        roster = roster,
        player = player,
        wires = function(defs: any, side: string)
            if side == "server" then return end
            defs[BEAT]:onClient(function(value: number)
                table.insert(heard, value)
            end)
        end,
    })
    return {
        wire = pair.wire,
        player = pair.player,
        server = pair.server,
        client = pair.client,
        heard = heard,
    }
end

-- Both namespaces, on one roster, with the client already in the place.
local function paired(): Pair
    local roster = Doubles.roster()
    local player = roster:join(SENDER)
    return { [ARENA] = opened(ARENA, roster, player), [LOBBY] = opened(LOBBY, roster, player) }
end

-- A fire left where a caller left it, because what a flush did not reach is half of what it is.
local function queues(of: Pair, space: string, value: number)
    of[space].server.defs[BEAT]:fireClient(of[space].player, value)
end

-- Every record a budgeted flush is asked to carry, queued in one go.
local function stocks(set: any)
    for id = 1, RECORDS do
        set:add(id, { [TEXT] = spelled(id) })
    end
end

-- A flush of one namespace, at a budget or at whatever the library picks, and a round on every
-- lane afterwards.
local function drains(of: Pair, space: string, maxBytes: number?)
    of[space].server.session:flush(maxBytes)
    for _, one in of do
        one.wire:settle()
    end
end

-- Frames put on that namespace's lane, counted by the lane rather than by the library.
local function frames(of: Pair, space: string): number
    return of[space].wire:moved().frames
end

-- What the client holds of that namespace's set, which is what a budget decided.
local function holding(of: Pair, space: string): number
    return #of[space].client.defs[BOARD]
end

-- The same, read as a throttle: some of the records and not all of them.
local function throttled(of: Pair, space: string): number
    local held = holding(of, space)
    Expect.holds(held > 0, `{space} carried no record at all at the floor`)
    Expect.holds(held < RECORDS, `{held} of {RECORDS} reached {space}, so nothing was bound`)
    return held
end

-- Public --------------------------------------------------------------

return {
    -- A flush that names one namespace, with the other one holding traffic.
    Harness.case("ns.independent-flush", function()
        local of = paired()
        queues(of, ARENA, CARRIED)
        queues(of, LOBBY, OTHER)
        local waiting = frames(of, LOBBY)

        drains(of, ARENA)
        Expect.equal(of[ARENA].heard, { CARRIED })
        Expect.equal(frames(of, LOBBY), waiting)

        drains(of, LOBBY)
        Expect.equal(of[LOBBY].heard, { OTHER })
    end),

    -- The two argument form, and the number belonging to the flush that named the namespace rather
    -- than to a pool the second namespace draws what is left from.
    Harness.case("life.flush-one-budget", function()
        local of = paired()
        stocks(of[ARENA].server.defs[BOARD])
        stocks(of[LOBBY].server.defs[BOARD])

        drains(of, ARENA, FLOOR)
        local mine = throttled(of, ARENA)
        Expect.equal(holding(of, LOBBY), 0)

        drains(of, LOBBY, FLOOR)
        Expect.equal(throttled(of, LOBBY), mine)
        Expect.equal(holding(of, ARENA), mine)
    end),

    -- A budget with packets and state both queued behind it: the budget is a state throttle and
    -- nothing else, since a packet is queued intent and dropping one changes what the program did.
    Harness.case("ns.budget-state-only", function()
        local of = paired()
        stocks(of[ARENA].server.defs[BOARD])
        queues(of, ARENA, CARRIED)
        queues(of, ARENA, PASSED)

        drains(of, ARENA, FLOOR)
        Expect.equal(of[ARENA].heard, { CARRIED, PASSED })
        throttled(of, ARENA)

        drains(of, ARENA, ROOM)
        Expect.equal(holding(of, ARENA), RECORDS)
    end),

    -- A flush assembled past what one fire may carry goes out as several fires in order, every
    -- payload arrives once, and the namespace keeps working after.
    Harness.case("ns.frame-ceiling", function()
        local of = paired()
        local heard: { number } = {}
        of[ARENA].client.defs[HEAVY]:onClient(function(text: string)
            table.insert(heard, #text)
        end)
        local count = math.ceil(Protocol.MAX_FIRE / HEAVIEST) + 1
        for index = 1, count do
            local text = string.rep(FILLER, HEAVIEST - index)
            of[ARENA].server.defs[HEAVY]:fireClient(of[ARENA].player, text)
        end
        local before = frames(of, ARENA)
        drains(of, ARENA)
        Expect.holds(
            frames(of, ARENA) - before > 1,
            "a flush past the ceiling went out as one fire"
        )
        Expect.equal(#heard, count)
        for index = 1, count do
            Expect.equal(heard[index], HEAVIEST - index)
        end

        of[ARENA].server.defs[HEAVY]:fireClient(of[ARENA].player, "after")
        drains(of, ARENA)
        Expect.equal(heard[count + 1], 5)
    end),

    -- A client that arrived after the records did, caught up under a budget: the backlog goes over
    -- as chunks and each takes its room out of what is left.
    Harness.case("ns.catch-up-budget", function()
        local of = Replica.open({ space = ARENA, defined = defined }, SENDER)
        stocks(of.server.defs[BOARD])
        Replica.ships(of)

        local late = Replica.joins(of, LATE)
        of.server.session:flush(FLOOR)
        of.wire:settle()

        local held = #late.machine.defs[BOARD]
        Expect.holds(held > 0, "a late join under a budget was caught up on nothing at all")
        Expect.holds(
            held < RECORDS,
            `a late join took all {RECORDS} records at a budget of {FLOOR}`
        )
    end),
}
