--!strict
--!optimize 2
--[[
    A flush with a name and a number on it: which namespace it drains, and how much of that
    namespace's state it carries.
]]

local Lync = require ("@src")
local Protocol = require ("@src/wire/Protocol")

local Doubles = require ("@fixtures/Doubles")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Replica = require ("@test/harness/Replica")

-- Constants -----------------------------------------------------------

--[[
    Two namespaces, because every claim here is about a boundary and a boundary needs a second side.
    Both are opened by every check, so the one a check leaves alone is what says the other was
    reached on purpose.
]]
const ARENA = "arena"
const LOBBY = "lobby"

-- The one client, because a budget is per client and one of them is what makes the number plain.
const SENDER = "alice"

-- The one who arrives after the records did, which is what a catch-up is owed to.
const LATE = "bob"

-- One packet and one set in each namespace, under the same two names in both.
const BEAT = "beat"
const BOARD = "board"

-- The one field a record carries, which is the weight a budget is measured against.
const TEXT = "text"

-- The bound on what a fire carries, and the width every record is padded to.
const TOP = 100
const WIDE = 128

--[[
    A packet wide enough that a handful of fires outweigh what one fire may carry. `MAX_FIRE` is a
    million bytes and a flush assembles whatever was queued, so the only way to the guard is a frame
    built out of fires nobody drained. Sixty thousand a fire reaches it in under twenty of them.
]]
const HEAVY = "heavy"
const HEAVIEST = 60000

-- What a record is padded with, so records of two ids differ and records of one id do not.
const FILLER = "x"

--[[
    Records stocked before a budgeted flush. Enough that the set outweighs the smallest legal budget
    several times over, so a check reading a partial delivery is reading a throttle rather than a
    rounding.
]]
const RECORDS = 40

-- The smallest budget a caller may pass, and one with more room than this file ever queues.
const FLOOR = Protocol.BUDGET_FLOOR
const ROOM = FLOOR * 64

-- What a fire carries, one per fire a check makes, so an arrival names the fire it came from.
const CARRIED = 7
const PASSED = 11
const OTHER = 23

-- Types ---------------------------------------------------------------

type Machine = Replica.Machine

-- One namespace on both machines, with what its client heard since the last reading.
type Space = {
    read wire: Doubles.Wire,
    read player: Player,
    read server: Machine,
    read client: Machine,
    read heard: { number },
}

-- The two of them, keyed by the names they were opened under.
type Pair = { [string]: Space }

-- Private -------------------------------------------------------------

-- A record's payload, distinct per id and the same width whatever the id is.
local function spelled (id: number): string
    local tail = tostring (id)
    return string.rep (FILLER, WIDE - #tail) .. tail
end

--[[
    The definitions one machine requires, built once a side and once a namespace. A budget is
    spent per namespace, so two of them have to be as separate here as two machines are.
]]
local function defined (): any
    return {
        [BEAT] = Lync.packet (Lync.int (0, TOP)),
        [BOARD] = Lync.replicate (Lync.struct ({ [TEXT] = Lync.str (1, WIDE) })),
        [HEAVY] = Lync.packet (Lync.str (1, HEAVIEST)),
    }
end

--[[
    One namespace: its own lane, a session either side of it, and a listener on the packet before
    the client starts.
]]
local function opened (space: string, roster: Doubles.Roster, player: Player): Space
    local heard: { number } = {}

    local pair = Replica.paired ({
        space = space,
        defined = defined,
        label = SENDER,
        roster = roster,
        player = player,
        wires = function (defs: any, side: string)
            if side == "server" then return end

            defs[BEAT]:onClient (function (value: number) table.insert (heard, value) end)
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
local function paired (): Pair
    local roster = Doubles.roster ()
    local player = roster:join (SENDER)

    return { [ARENA] = opened (ARENA, roster, player), [LOBBY] = opened (LOBBY, roster, player) }
end

-- A fire left where a caller left it, because half of what a flush is is what it did not reach.
local function queues (of: Pair, space: string, value: number)
    of[space].server.defs[BEAT]:fireClient (of[space].player, value)
end

-- Every record a budgeted flush is asked to carry, queued in one go.
local function stocks (of: Pair, space: string)
    for id = 1, RECORDS do
        of[space].server.defs[BOARD]:add (id, { [TEXT] = spelled (id) })
    end
end

--[[
    A flush of one namespace, at a budget or at whatever the library picks, and a round on every
    lane afterwards.
]]
local function drains (of: Pair, space: string, maxBytes: number?)
    of[space].server.session:flush (maxBytes)

    for _, one in of do
        one.wire:settle ()
    end
end

-- Every fire that namespace's client was handed, in the order it was handed them.
local function heard (of: Pair, space: string): { number } return of[space].heard end

-- Frames put on that namespace's lane, counted by the lane rather than by the library.
local function frames (of: Pair, space: string): number return of[space].wire:moved ().frames end

-- What the client holds of that namespace's set, which is what a budget decided.
local function holding (of: Pair, space: string): number return #of[space].client.defs[BOARD] end

-- The same, read as a throttle: some of the records and not all of them.
local function throttled (of: Pair, space: string): number
    local held = holding (of, space)

    Expect.holds (held > 0, `{space} carried no record at all at the floor`)
    Expect.holds (held < RECORDS, `{held} of {RECORDS} reached {space}, so nothing was bound`)
    return held
end

-- Public --------------------------------------------------------------

return {
    --[[
        A flush that names one namespace, with the other one holding traffic. A flush reaching both
        would make the second cost whatever the first costs, which is what a caller opened a second
        namespace to avoid.
    ]]
    Harness.case ("ns.independent-flush", function ()
        local of = paired ()

        queues (of, ARENA, CARRIED)
        queues (of, LOBBY, OTHER)
        local waiting = frames (of, LOBBY)

        drains (of, ARENA)

        Expect.equal (heard (of, ARENA), { CARRIED })
        Expect.equal (frames (of, LOBBY), waiting)

        drains (of, LOBBY)
        Expect.equal (heard (of, LOBBY), { OTHER })
    end),

    --[[
        The two argument form, and the number belonging to the flush that named the namespace. A
        library treating the budget as a pool would hand the second namespace whatever the first
        left, and the shortfall would move with traffic the caller was not thinking about.
    ]]
    Harness.case ("life.flush-one-budget", function ()
        local of = paired ()

        stocks (of, ARENA)
        stocks (of, LOBBY)

        drains (of, ARENA, FLOOR)
        local mine = throttled (of, ARENA)
        Expect.equal (holding (of, LOBBY), 0)

        drains (of, LOBBY, FLOOR)

        Expect.equal (throttled (of, LOBBY), mine)
        Expect.equal (holding (of, ARENA), mine)
    end),

    --[[
        A budget with packets and state both queued behind it. The budget is a state throttle and
        nothing else: a packet is queued intent and dropping one changes what the program did, where
        a section that waits a flush costs latency and nothing more.
    ]]
    Harness.case ("ns.budget-state-only", function ()
        local of = paired ()

        stocks (of, ARENA)
        queues (of, ARENA, CARRIED)
        queues (of, ARENA, PASSED)

        drains (of, ARENA, FLOOR)

        Expect.equal (heard (of, ARENA), { CARRIED, PASSED })
        throttled (of, ARENA)

        drains (of, ARENA, ROOM)
        Expect.equal (holding (of, ARENA), RECORDS)
    end),

    --[[
        A frame assembled past what one fire may carry. The budget is a state throttle and a packet
        is queued intent, so nothing above the outbox bounds a loop that fires and never flushes,
        and the engine's own refusal names neither the namespace nor the size.
    ]]
    Harness.case ("ns.frame-ceiling", function ()
        local of = paired ()
        local block = string.rep (FILLER, HEAVIEST)

        for _ = 1, math.ceil (Protocol.MAX_FIRE / HEAVIEST) + 1 do
            of[ARENA].server.defs[HEAVY]:fireClient (of[ARENA].player, block)
        end

        Expect.throws (function () of[ARENA].server.session:flush () end, "one fire takes")
    end),

    --[[
        A client that arrived after the records did, caught up under a budget. The backlog goes
        over as chunks and each takes its room out of what is left, so one flush hands over some
        of the set and the rest waits. A catch-up cutting every chunk against the room the first
        one had would hand the whole backlog over at a budget that never moved.
    ]]
    Harness.case ("ns.catch-up-budget", function ()
        local of = Replica.open ({ space = ARENA, defined = defined }, SENDER)

        for id = 1, RECORDS do
            of.server.defs[BOARD]:add (id, { [TEXT] = spelled (id) })
        end
        Replica.ships (of)

        local late = Replica.joins (of, LATE)
        of.server.session:flush (FLOOR)
        of.wire:settle ()

        local held = #late.machine.defs[BOARD]
        Expect.holds (held > 0, "a late join under a budget was caught up on nothing at all")
        Expect.holds (
            held < RECORDS,
            `a late join took all {RECORDS} records at a budget of {FLOOR}`
        )
    end),
}
