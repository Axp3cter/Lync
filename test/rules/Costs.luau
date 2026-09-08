--!strict
--!optimize 2
-- What a fire costs on the lane that carried it, read off the lane.

local Codecs = require("@src/codec")
local Packet = require("@src/api/Packet")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Replica = require("@test/harness/Replica")

-- This file's namespace, and the crowded one beside it.
local SPACE = "costs"
local NAMED = "crowd"

-- The one client, because every claim here is about a number rather than an audience.
local SENDER = "alice"

-- A plain packet, one that coalesces, and one wide enough for its bytes to be worth reading.
local PLAIN = "plain"
local LATEST = "latest"
local WIDE = "wide"

-- The bound on what a narrow fire carries, and the two on what a wide one does.
local TOP = 100
local SHORTEST = 1
local LONGEST = 64

-- Fires a run makes: more than one, and few, since the claim is a comparison rather than volume.
local RUN = 5

-- What a single fire carries, narrow and wide.
local CARRIED = 7
local SPELLED = "a payload wider than a number"

-- A namespace wide enough that its definition id spends five bits, which is what makes the header
-- a place a count can be spelled for nothing. The one value every crowded fire carries.
local CROWD = 20
local ONE = 1

type Run = Replica.Paired

-- Private -------------------------------------------------------------

local function defined(): any
    return {
        [PLAIN] = Packet.new(Codecs.int(0, TOP)),
        [LATEST] = Packet.new(Codecs.int(0, TOP)):newest(),
        [WIDE] = Packet.new(Codecs.str(SHORTEST, LONGEST)),
    }
end

local function crowded(): any
    local of: { [string]: any } = {}
    for index = 1, CROWD do
        of[`{NAMED}{index}`] = Packet.new(Codecs.int(0, TOP))
    end
    return of
end

-- A listener on every packet on the client, attached before the session starts.
local function listening(defs: any, side: string)
    if side == "server" then return end
    for _, packet in defs do
        packet:onClient(function() end)
    end
end

-- Two machines on one lane that never faults, since a lane losing frames would be a second reason
-- for two numbers to disagree.
local function opened(space: string, defs: () -> any): Run
    return Replica.paired({ space = space, defined = defs, label = SENDER, wires = listening })
end

-- What one flush of the fires `run` makes puts on the lane.
local function cost(of: Run, run: () -> ()): number
    local before = Replica.carried(of)
    run()
    of.server.session:flush()
    of.wire:settle()
    local moved = Replica.carried(of) - before
    Expect.holds(moved > 0, "a flush of fires put nothing on the lane")
    return moved
end

-- A run of fires under one definition, all of them inside one flush, and what it cost.
local function runs(of: Run, name: string): number
    return cost(of, function()
        for index = 1, RUN do
            of.server.defs[name]:fireClient(of.player, index)
        end
    end)
end

-- Public --------------------------------------------------------------

return {
    -- A run of fires that coalesce costs less than the same run of fires that do not.
    Harness.case("cost.latest-run", function()
        local of = opened(SPACE, defined)
        local many = runs(of, PLAIN)
        local once = runs(of, LATEST)
        Expect.holds(once < many, `{RUN} plain fires cost {many} and {RUN} latest cost {once}`)
    end),

    -- A fire of a known size and the bytes it puts on the lane, which is what a budget is set
    -- against.
    Harness.case("cost.wide-fire", function()
        local of = opened(SPACE, defined)
        local narrow = cost(of, function()
            of.server.defs[PLAIN]:fireClient(of.player, CARRIED)
        end)
        local wide = cost(of, function()
            of.server.defs[WIDE]:fireClient(of.player, SPELLED)
        end)
        Expect.holds(wide > narrow, `a narrow fire cost {narrow} and a wide one {wide}`)
    end),

    -- What one fire costs where twenty definitions share the namespace: the count a block states
    -- rides in bits the definition id was already rounding away, so one payload costs a byte and
    -- that payload. Read against a pair, since the two share the header.
    Harness.case("cost.header-one-byte", function()
        local of = opened(NAMED, crowded)
        local sole = of.server.defs[`{NAMED}1`]
        local first = cost(of, function()
            sole:fireClient(of.player, ONE)
        end)
        local both = cost(of, function()
            sole:fireClient(of.player, ONE)
            sole:fireClient(of.player, ONE)
        end)

        -- The payload apiece, which the pair spends twice and the lone fire once beside its header.
        local payload = both - first
        Expect.holds(payload > 0, `a pair of fires cost {both} and one cost {first}`)
        Expect.equal(first - payload, ONE)
    end),
}
