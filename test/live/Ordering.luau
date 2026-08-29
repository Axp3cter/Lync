--!strict
--!optimize 2
-- The delivery facts the wire rides on, read off a remote of this suite's own.

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

local Players = game:GetService ("Players")
local RunService = game:GetService ("RunService")

-- Constants -----------------------------------------------------------

--[[
    The remote every check here fires on. One instance, because one instance is what the claim is
    about: two would make the interleaved sequence two lanes, and the engine promises nothing about
    the order between them.
]]
const NAME = "ordering"

--[[
    Fires per sequence, and the bytes each carries. Eight is past any plausible reorder window and
    short enough that a failing line prints whole. The payload is four bytes rather than an argument
    because the serialization pin below needs a buffer, and a sequence carrying two payload shapes
    would be two things to be right about.
]]
const RUNS = 8
const WIDTH = 4

--[[
    The two words the fire-time probe writes into one buffer: the one it holds when the fire is
    issued and the one written immediately after. A receiver that reads the second saw the engine
    serialize late, which is the failure.
]]
const KEPT = 0x600DF00D
const LOST = 0xDEADBEEF

--[[
    How long a client waits for a sequence, and how long it spends looking for the remote when it
    loads. The first is short because the runner has already brought the two runs together and what
    is left is a round trip. The second is long because it runs before that meeting, while the
    server may still be on its way to creating anything.
]]
const PATIENCE = 10
const FINDING = 60

-- Private -------------------------------------------------------------

--[[
    What this client has been handed under one name. A bucket per check, so the four runs
    accumulate side by side and a client that is behind the server on one is not reading another's
    arrivals.
]]
local heard: { [string]: { number } } = {}

local function held (which: string): { number }
    local got = heard[which]
    if got ~= nil then return got end

    got = {}
    heard[which] = got
    return got
end

--[[
    The remote, made by the server and found by the client. It hangs off this module rather than off
    the test tree, so nothing else can be firing on it and the instance the claim is about is the
    instance the claim is about.
]]
local remote: RemoteEvent

if RunService:IsServer () then
    local made = Instance.new ("RemoteEvent")
    made.Name = NAME
    made.Parent = script
    remote = made
else
    local found = script:WaitForChild (NAME, FINDING)
    remote = assert (found, `no {NAME} remote appeared in {FINDING} s`) :: RemoteEvent

    remote.OnClientEvent:Connect (function (bytes: buffer, which: string, to: Player)
        if to ~= Players.LocalPlayer then return end
        table.insert (held (which), buffer.readu32 (bytes, 0))
    end)
end

--[[
    One fire, carrying its index, the sequence it belongs to, and the client it is for. A broadcast
    reaches every client and names one, so each keeps its own subsequence and drops the rest: that
    is what lets one server sequence per client run at once without the clients reading each other's
    traffic.
]]
local function fires (which: string, who: Player, index: number, broadcast: boolean)
    local bytes = buffer.create (WIDTH)
    buffer.writeu32 (bytes, 0, index)

    if broadcast then
        remote:FireAllClients (bytes, which, who)
        return
    end
    remote:FireClient (who, bytes, which, who)
end

-- Everyone here, and the refusal that keeps a run with nobody on it from passing.
local function watching (): { Player }
    local here = Players:GetPlayers ()
    Expect.holds (#here > 0, "no client is here to fire at")
    return here
end

--[[
    One sequence per client, fired a step at a time rather than a client at a time, with `broadcast`
    deciding each fire's form.
]]
local function sequenced (which: string, broadcast: (number) -> boolean)
    local here = watching ()

    for index = 1, RUNS do
        for _, who in here do
            fires (which, who, index, broadcast (index))
        end
    end
end

--[[
    A sequence as this client received it. The claim is that the first `RUNS` arrivals are one,
    two, three and so on. What arrived afterwards is left alone: the wait returns the moment the
    run is complete, so a later arrival races the assertion rather than saying anything.
]]
local function ordered (which: string)
    local got = held (which)
    Harness.awaits (`{RUNS} {which} fires`, function () return #got >= RUNS end, PATIENCE)

    for index = 1, RUNS do
        Expect.equal (got[index], index)
    end
end

-- Public --------------------------------------------------------------

return {
    --[[
        A run of targeted fires. The plainest form of the claim and the one every other reading
        rests on: a client is handed what it was sent, in the order it was sent, on a lane the
        engine calls ordered.
    ]]
    Harness.pair ("order.targeted", function ()
        sequenced ("targeted", function (): boolean return false end)
    end, function () ordered ("targeted") end),

    -- A run of broadcasts, which is the same claim where the engine chose the recipients.
    Harness.pair ("order.broadcast", function ()
        sequenced ("broadcast", function (): boolean return true end)
    end, function () ordered ("broadcast") end),

    --[[
        The two forms alternating on one instance, which is the fact the design leans on: a
        uniform flush goes out as one broadcast and any other goes per client, so a lane is a
        stream of both and its order is promised across the pair. Were the engine to order them
        apart, no byte would say so, since the frames are the same either way.
    ]]
    Harness.pair ("order.interleaved", function ()
        sequenced ("interleaved", function (index: number): boolean return index % 2 == 0 end)
    end, function () ordered ("interleaved") end),

    --[[
        A buffer fired and then written over. The engine serializes an argument at call time, so
        the library may reuse one frame buffer between fires. A receiver reading the second word
        would mean a reference was taken and every fire after the first carried the last frame's
        bytes. One buffer across every client because that is exactly what the library does.
    ]]
    Harness.pair ("order.fire-time", function ()
        local scratch = buffer.create (WIDTH)

        for _, who in watching () do
            buffer.writeu32 (scratch, 0, KEPT)
            remote:FireClient (who, scratch, "fire-time", who)
            buffer.writeu32 (scratch, 0, LOST)
        end
    end, function ()
        local got = held ("fire-time")
        Harness.awaits ("the fire-time probe", function (): boolean return #got >= 1 end, PATIENCE)
        Expect.equal (got[1], KEPT)
    end),
}
