--!strict
--!optimize 2
-- One namespace's endpoint: the buffers it reuses, the clients it may reach, and what is queued.

local Blocks = require ("@src/channel/Blocks")
local Recipients = require ("@src/channel/Recipients")
local Tally = require ("@src/kernel/Tally")
local Transport = require ("@src/channel/Transport")

local Link = {}

-- Types ---------------------------------------------------------------

--[[
    A namespace's outbound state, as a record rather than a handle, because everything here is read
    by an assembler that walks the buckets and sums the lengths and a class would put a method in
    front of every one of those reads. Four lists, since a frame is assembled per client and two of
    them are the part that is the same for all, and the lossy pair has no classes.
]]
export type Link = {
    read name: string,
    read isServer: boolean,
    read transport: Transport.Transport,
    read tally: Tally.Tally,
    read scratch: buffer,

    --[[
        The run of fires still open, and the buffer it is being written into. Its own rather than
        the scratch above, because a section written between two fires would land on top of it and
        a run is only sealed when something else asks to be sent or the flush comes round.
    ]]
    read pending: buffer,
    read room: number,

    -- What the open run is held to: how many it may carry, and the widest one payload may come to.
    runs: number,
    widest: number,
    holds: number,

    -- The tally row of the definition the open run carries, so a fire does not name it again.
    tallied: Tally.Row?,
    wrote: number,
    over: any,
    kind: number,

    -- The id the run's last question or answer named, which the next one climbs from.
    last: number,
    toward: Player?,
    lossy: boolean,
    seq: number,
    epoch: number,
    sending: boolean,
    read audience: { Player },
    read ready: Recipients.Ready,
    read shared: { { Blocks.Block } },
    read divergent: { [Player]: { { Blocks.Block } } },
    read sharedLossy: { Blocks.Block },
    read divergentLossy: { [Player]: { Blocks.Block } },
}

-- Private -------------------------------------------------------------

-- One bucket per class, which is what a reliable queue is on either side of the shared line.
local function buckets (): { { Blocks.Block } }
    local out = table.create (Blocks.CLASSES) :: { { Blocks.Block } }
    for index = 1, Blocks.CLASSES do
        out[index] = {}
    end
    return out
end

-- Public --------------------------------------------------------------

-- An endpoint, before its remotes exist.
function Link.new (
    name: string,
    side: Transport.Side,
    room: number,
    transport: Transport.Transport,
    tally: Tally.Tally
): Link
    return {
        name = name,
        isServer = side == "server",
        transport = transport,
        tally = tally,
        scratch = buffer.create (room),
        pending = buffer.create (room),
        room = room,
        runs = 0,
        widest = 0,
        holds = 0,
        tallied = nil,
        wrote = 0,
        over = nil,
        kind = 0,
        last = 0,
        toward = nil,
        lossy = false,
        seq = 0,
        epoch = 0,
        sending = side == "server",
        audience = {},
        ready = {},
        shared = buckets (),
        divergent = {},
        sharedLossy = {},
        divergentLossy = {},
    }
end

function Link.open (of: Link) of.transport:open () end

-- A client this endpoint may now send to, and the two lists its targeted blocks queue in.
function Link.admit (of: Link, player: Player)
    of.ready[player] = true
    of.divergent[player] = buckets ()
    of.divergentLossy[player] = {}
end

-- A client gone, and everything queued for them let go.
function Link.drop (of: Link, player: Player)
    of.ready[player] = nil

    local held = of.divergent[player]
    if held ~= nil then
        for _, one in held do
            Blocks.drain (one)
        end
        of.divergent[player] = nil
    end

    local lossy = of.divergentLossy[player]
    if lossy == nil then return end

    Blocks.drain (lossy)
    of.divergentLossy[player] = nil
end

-- The next block's place in its bucket, which is the half of a merge key a class does not decide.
function Link.next (of: Link): number
    local at = of.seq
    of.seq = at + 1
    return at
end

-- The sequence back to nothing, which a flush does once every bucket it filled has drained.
function Link.rewind (of: Link) of.seq = 0 end

-- An endpoint let go: nothing queued, nobody ready, and the remotes heard no longer.
function Link.close (of: Link)
    of.sending = false

    for _, one in of.shared do
        Blocks.drain (one)
    end
    Blocks.drain (of.sharedLossy)

    --[[
        Over the readiness set, because a client is admitted and given its buckets in one call, so
        that set is the list of everyone holding any. Clearing a key mid-walk is what `next` allows.
    ]]
    for player in of.ready do
        Link.drop (of, player)
    end

    table.clear (of.audience)
    of.transport:close ()
end

return table.freeze (Link)
