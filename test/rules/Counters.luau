--!strict
--!optimize 2
-- What a namespace counted, held against the lane that carried it.

local Lync = require ("@src")
local Types = require ("@src/Types")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Replica = require ("@test/harness/Replica")

-- Constants -----------------------------------------------------------

-- This file's namespace, which nothing else opens.
const SPACE = "counters"

-- The one client, because every claim here is about a number rather than an audience.
const SENDER = "alice"

-- How many fires ride one block below, which is more than the single fire a frame carries.
const RIDING = 3

--[[
    Four packets, and what separates each from the next is the one thing a check reads a counter
    against.
]]
const PLAIN = "plain"
const LATEST = "latest"
const WIDE = "wide"
const GUARDED = "guarded"

-- A set, since a section is composed rather than fired and is counted where it is composed.
const ROSTER = "roster"

-- The bound on what a narrow fire carries, and the two on what a wide one does.
const TOP = 100
const SHORTEST = 1
const LONGEST = 64

-- What the guard says, in words nothing else in the tree uses.
const REFUSED = "the counter guard turned it away"

--[[
    Fires a run makes. More than one, because a counter moving by one is a counter that could be
    moving by anything, and few, because the claim is exactness rather than volume and the run is
    made once per definition.
]]
const RUN = 5

-- What a single fire carries. A run draws its own values, so these are the three handed over.
const CARRIED = 7
const SPELLED = "a payload wider than a number"
const OFFERED = true

-- Types ---------------------------------------------------------------

type Machine = Replica.Machine
type Run = Replica.Paired

-- Private -------------------------------------------------------------

--[[
    A plain fire, one that coalesces, one wide enough for its bytes to be worth reading, and one the
    far side turns away, with the set beside them.
]]
local function defined (): any
    return {
        [PLAIN] = Lync.packet (Lync.int (0, TOP)),
        [LATEST] = Lync.packet (Lync.int (0, TOP)):newest (),
        [WIDE] = Lync.packet (Lync.str (SHORTEST, LONGEST)),
        [GUARDED] = Lync.packet (Lync.bool ():validate (function (): string? return REFUSED end)),
        [ROSTER] = Lync.replicate (Lync.struct ({ score = Lync.int (0, TOP) })),
    }
end

--[[
    A listener on every definition, on the side that receives it, attached before the session starts
    because that is where a caller writes one.
]]
local function listening (defs: any, side: string)
    for _, held in defs do
        local of: any = held

        -- A set is listened to by what it holds rather than by a fire, so it is left to itself.
        if rawget (of, "onServer") == nil and of.onServer == nil then continue end

        if side == "server" then
            of:onServer (function () end)
            continue
        end
        of:onClient (function () end)
    end
end

--[[
    A namespace wide enough that its definition id spends five bits, which is what makes the header
    a place a count can be spelled for nothing. Under sixteen definitions the id leaves so much of
    its byte spare that a header would come to one however the room were counted.
]]
const CROWD = 20
const NAMED = "crowd"

local function crowded (): any
    local of: { [string]: any } = {}
    for index = 1, CROWD do
        of[`{NAMED}{index}`] = Lync.packet (Lync.int (0, TOP))
    end
    return of
end

--[[
    Two machines on one lane that never faults, since a counter is what is under test here and a
    lane losing frames would be a second reason for a number to disagree with the one beside it.
]]
local function opened (): Run
    return Replica.paired ({ space = SPACE, defined = defined, label = SENDER, wires = listening })
end

-- A machine's whole namespace line, which is the reading above the rows.
local function whole (of: Machine): Types.Stats return of.session:stats () end

-- One definition's line in that reading, which is where every count here is read.
local function row (of: Machine, name: string): Types.DefinitionStats
    local held = whole (of).definitions[name]
    Expect.holds (held ~= nil, `{name} has no line in the snapshot`)
    return held
end

local crossed = Replica.carried

-- One fire from the server, addressed rather than broadcast, since there is one client.
local function fromServer (of: Run, name: string, value: any)
    of.server.defs[name]:fireClient (of.player, value)
    of.server.session:flush ()
    of.wire:settle ()
end

-- The same the other way, which is the direction a drop is read in.
local function fromClient (of: Run, name: string, value: any)
    of.client.defs[name]:fireServer (value)
    of.client.session:flush ()
    of.wire:settle ()
end

-- A run of fires under one definition, all of them inside one flush.
local function runs (of: Run, name: string)
    for index = 1, RUN do
        of.server.defs[name]:fireClient (of.player, index)
    end

    of.server.session:flush ()
    of.wire:settle ()
end

--[[
    One fire, and the three counters that have to agree with the lane about it: the namespace's, the
    definition's own line, and the receiving machine's.
]]
local function costs (of: Run, name: string, value: any): number
    local before = whole (of.server).sentBytes
    local mine = row (of.server, name).sentBytes
    local theirs = whole (of.client).receivedBytes
    local was = crossed (of)

    fromServer (of, name, value)
    local moved = crossed (of) - was

    Expect.holds (moved > 0, `a fire of {name} put nothing on the lane`)
    Expect.equal (whole (of.server).sentBytes - before, moved)
    Expect.equal (row (of.server, name).sentBytes - mine, moved)
    Expect.equal (whole (of.client).receivedBytes - theirs, moved)
    return moved
end

-- Public --------------------------------------------------------------

return {
    --[[
        N fires and a counter that moved by N, which is what makes two snapshots a measurement. A
        counter written when the flush drains rather than when the call is made reads short by
        whatever was still queued when the second snapshot was taken.
    ]]
    Harness.case ("stats.diff-exact", function ()
        local of = opened ()

        local before = row (of.server, PLAIN).sent
        local was = crossed (of)
        runs (of, PLAIN)
        local many = crossed (of) - was

        Expect.equal (row (of.server, PLAIN).sent - before, RUN)
        Expect.equal (row (of.server, LATEST).sent, 0)

        before = row (of.server, LATEST).sent
        was = crossed (of)
        runs (of, LATEST)
        local once = crossed (of) - was

        Expect.equal (row (of.server, LATEST).sent - before, RUN)
        Expect.holds (once < many, `{RUN} plain fires cost {many} and {RUN} latest cost {once}`)
    end),

    --[[
        A fire of a known size and the bytes it is charged. A byte count is what a budget is set
        against, so a number merely proportional to the traffic is worse than none: it reads like
        bytes, divides like bytes, and sets a budget nobody can hold.
    ]]
    Harness.case ("stats.bytes", function ()
        local of = opened ()

        local narrow = costs (of, PLAIN, CARRIED)
        local wide = costs (of, WIDE, SPELLED)

        Expect.holds (wide > narrow, `a narrow fire cost {narrow} and a wide one {wide}`)
    end),

    --[[
        A payload the machine it reached would not take. A client whose traffic is being refused
        looks exactly like a client that is quiet, and this counter is the only thing telling the
        two apart, which is why an anti-cheat reads a rate off it.
    ]]
    Harness.case ("stats.drops", function ()
        local of = opened ()

        local mine = whole (of.server).drops
        local theirs = whole (of.client).drops
        local charged = row (of.server, GUARDED).drops
        local sent = row (of.client, GUARDED).sent

        fromClient (of, GUARDED, OFFERED)

        Expect.equal (whole (of.server).drops - mine, 1)
        Expect.equal (row (of.server, GUARDED).drops - charged, 1)
        Expect.equal (whole (of.client).drops, theirs)
        Expect.equal (row (of.client, GUARDED).sent - sent, 1)

        mine = whole (of.server).drops
        local passed = row (of.server, PLAIN).drops

        fromClient (of, PLAIN, CARRIED)

        Expect.equal (whole (of.server).drops, mine)
        Expect.equal (row (of.server, PLAIN).drops - passed, 0)
    end),

    --[[
        A run of fires in one block, counted once each. A block carrying many fires of the one
        definition arrives as a single frame, so the line has to be told how many rode in it
        rather than that a frame came: counting the frame would read a run of many as one.
    ]]
    Harness.case ("stats.received-per-fire-of-a-run", function ()
        local of = opened ()
        local held = row (of.client, PLAIN).received

        for _ = 1, RIDING do
            of.server.defs[PLAIN]:fireClient (of.player, CARRIED)
        end
        of.server.session:flush ()
        of.wire:settle ()

        Expect.equal (row (of.client, PLAIN).received - held, RIDING)
    end),

    --[[
        What one definition's line says arrived, against what the machine says arrived. A line that
        counted nothing leaves a reader unable to say which definition the traffic was, and one
        that counted twice reads a share larger than the whole, which is the reading that convicts
        it: a definition cannot have carried more of a frame than the frame itself carried.
    ]]
    Harness.case ("stats.received-per-definition", function ()
        local of = opened ()

        local mine = row (of.client, PLAIN).receivedBytes
        local held = row (of.client, PLAIN).received
        local all = whole (of.client).receivedBytes

        fromServer (of, PLAIN, CARRIED)

        local got = row (of.client, PLAIN).receivedBytes - mine
        local frame = whole (of.client).receivedBytes - all

        Expect.equal (row (of.client, PLAIN).received - held, 1)
        Expect.holds (got > 0, "the line of the definition that arrived counted none of it")
        Expect.holds (got <= frame, `a line counted {got} bytes of a frame carrying {frame}`)
    end),

    --[[
        A set's section, counted where it is composed. A section is not a fire and takes the path
        no packet does, so a namespace counting every fire correctly can still say nothing about
        the traffic a replicated set is, which is the traffic a place has most of.
    ]]
    Harness.case ("stats.section-counted", function ()
        local of = opened ()
        local set = of.server.defs[ROSTER]

        local mine = row (of.server, ROSTER).sentBytes
        local all = whole (of.server).sentBytes

        set:add (1, { score = CARRIED })
        of.server.session:flush ()
        of.wire:settle ()

        local put = row (of.server, ROSTER).sentBytes - mine
        local frame = whole (of.server).sentBytes - all

        Expect.holds (put > 0, "a set composed a section its own line counted none of")
        Expect.holds (put <= frame, `a line counted {put} bytes of a frame carrying {frame}`)
    end),
    --[[
        What one fire costs where twenty definitions share the namespace. The count a block states
        rides in bits the definition id was already rounding away, so one payload costs a byte and
        that payload. Read against a pair, since the two share the header, so what the second adds
        is its own payload and a header that had grown would show.
    ]]
    Harness.case ("stats.header-costs-one-byte", function ()
        const ONE = 1

        local of = Replica.paired ({
            space = NAMED,
            defined = crowded,
            label = SENDER,
            wires = listening,
        })

        local name = `{NAMED}1`
        local sole = of.server.defs[name]

        sole:fireClient (of.player, ONE)
        of.server.session:flush ()
        of.wire:settle ()

        local first = row (of.server, name).sentBytes

        sole:fireClient (of.player, ONE)
        sole:fireClient (of.player, ONE)
        of.server.session:flush ()
        of.wire:settle ()

        local both = row (of.server, name).sentBytes - first

        -- The payload apiece, which the pair spends twice and the lone fire once beside its header.
        local payload = both - first
        Expect.holds (payload > 0, `a pair of fires cost {both} and one cost {first}`)
        Expect.equal (first - payload, ONE)
    end),
}
