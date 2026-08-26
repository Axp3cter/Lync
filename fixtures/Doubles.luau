--!strict
--!optimize 2
-- The two sanctioned fakes: the wire between two machines, and the players on them.

local Session = require ("@src/runtime/Session")
local Transport = require ("@src/channel/Transport")

local Doubles = {}

-- Constants -----------------------------------------------------------

--[[
    The one lane a fault reaches. Only the unreliable lane can lose, double or hold a frame: the
    reliable lane is lossless by contract, so faulting it would test a case that cannot happen.
]]
const LOSSY: Transport.Channel = "unreliable"

-- What a stub player is, since an engine will not make a real one on demand.
const STAND_IN = "Folder"

-- What a hexadecimal dump writes each byte as.
const DIGITS = "%02x"

-- Types ---------------------------------------------------------------

--[[
    The seam this module stands in for, taken from the module that owns it. A fake is only a fake of
    something, and writing the shape down here would mean the library and the thing standing in for
    it agreed by coincidence: the first change to a lane, a sidecar or a receiver would leave this
    file compiling, passing, and describing a transport nobody has.
]]
export type Channel = Transport.Channel
export type Sidecar = Transport.Sidecar
export type Received = Transport.Received
export type Transport = Transport.Transport

-- The roster a session takes, and the three more a case drives it with.
export type Roster = Session.Roster & {
    read join: (self: any, label: string) -> Player,
    read leave: (self: any, who: Player) -> (),
    read named: (self: any, label: string) -> Player?,
}

--[[
    How often the unreliable lane misbehaves, as fractions of one that sum to at most one: a frame
    is lost, delivered twice, held until the next round, or delivered once. One draw decides, so a
    case replays from its tape exactly.
]]
export type Faults = {
    read lose: number,
    read double: number,
    read hold: number,
}

--[[
    Counted where a frame is fired rather than where it lands, so `frames` and `bytes` are what the
    library asked the lane for and the three below are what the lane made of it. A frame the lane
    doubled was fired once and counts once here.
]]
export type Moved = {
    read frames: number,
    read bytes: number,
    read lost: number,
    read doubled: number,
    read held: number,
}

--[[
    A frame as a watcher sees it: which lane carried it, who sent it, who it named, the bytes, and
    the instances riding beside them.
]]
export type Carried = {
    read at: Channel,
    read from: Player?,
    read to: Player?,
    read bytes: buffer,
    read refs: Sidecar?,
}

-- The lane, from either end, and what it has carried.
export type Wire = {
    read server: (self: Wire) -> Transport,
    read client: (self: Wire, who: Player) -> Transport,
    read gone: (self: Wire, who: Player) -> (),
    read watch: (self: Wire, see: (Carried) -> ()) -> () -> (),
    read hands: (self: Wire, of: Carried) -> (),
    read deliver: (self: Wire) -> number,
    read settle: (self: Wire) -> number,
    read moved: (self: Wire) -> Moved,
}

-- What the lane keeps for itself: the two public records above, writable, and the state of one end.
type Frame = {
    at: Channel,
    from: Player?,
    to: Player?,
    bytes: buffer,
    refs: Sidecar?,
}

type Tally = {
    frames: number,
    bytes: number,
    lost: number,
    doubled: number,
    held: number,
}

type Side = {
    takes: { [Channel]: Received },
    opened: boolean,
}

-- Private -------------------------------------------------------------

--[[
    The bytes as the engine hands them on: a copy taken when the frame is fired. The library reuses
    one frame buffer between fires and is entitled to, because the engine serializes an argument at
    call time. A wire holding the caller's buffer would fail correct code and pass code that never
    sent what it meant.
]]
local function copied (bytes: buffer): buffer
    local size = buffer.len (bytes)
    local out = buffer.create (size)
    buffer.copy (out, 0, bytes, 0, size)
    return out
end

local function sided (): Side return { takes = {}, opened = false } end

-- Public --------------------------------------------------------------

-- A lane that behaves, which is what every suite but the lossy ones wants.
Doubles.PERFECT = table.freeze ({ lose = 0, double = 0, hold = 0 } :: Faults)

-- The two ends of a draw, and what a lane makes of each.
Doubles.FAULTED = 0
Doubles.CLEAN = 1

-- Flushes a drain is allowed before it is called a failure rather than a wait.
Doubles.ROUNDS = 64

--[[
    A lane that misbehaves to a script rather than to chance, one draw per faultable frame, cycled.

    A drawn lane makes a suite's claim about how often a frame vanishes, which is not what any of
    them are about. Scripted, a failure names the frame.
]]
function Doubles.scripted (rolls: { number }): () -> number
    local at = 0

    return function (): number
        at += 1
        return rolls[(at - 1) % #rolls + 1]
    end
end

--[[
    Two machines and the lane between them. A fire queues, and `deliver` moves one round of frames
    and no more, so a reply lands in the next round rather than inside the call that caused it. That
    is what a remote does, and what keeps a test from running a whole conversation inside one flush.
]]
function Doubles.wire (chance: Faults?, draw: (() -> number)?): Wire
    local faults = chance or Doubles.PERFECT
    local total = faults.lose + faults.double + faults.hold
    assert (total <= 1, `faults sum to {total}, which is more than every frame`)
    assert (total == 0 or draw ~= nil, "a faulting wire wants something to draw from")

    local server = sided ()
    local clients: { [Player]: Side } = {}
    local left: { [Player]: boolean } = {}
    local queued: { Frame } = {}
    local holding: { Frame } = {}
    local tally: Tally = { frames = 0, bytes = 0, lost = 0, doubled = 0, held = 0 }

    --[[
        A wire with no faults still draws, and always answers the same: past every band, which is
        the branch that hands the frame over once.
    ]]
    local roll = draw or function (): number return Doubles.CLEAN end

    local function sideOf (who: Player?): Side
        if who == nil then return server end

        local held = clients[who]
        if held == nil then
            held = sided ()
            clients[who] = held
        end
        return held
    end

    local function endpoint (owner: Player?): Transport
        local self = {}

        function self.open () sideOf (owner).opened = true end

        function self.close ()
            local side = sideOf (owner)
            side.opened = false
            side.takes = {}
        end

        function self.onReceive (_: any, at: Channel, take: Received)
            local side = sideOf (owner)
            side.takes[at] = take
        end

        function self.fire (_: any, at: Channel, to: Player?, bytes: buffer, refs: Sidecar?)
            assert (sideOf (owner).opened, "a closed transport fired")
            assert (owner == nil or to == nil, "a client fired at a recipient")

            tally.frames += 1
            tally.bytes += buffer.len (bytes)
            table.insert (queued, {
                at = at,
                from = owner,
                to = to,
                bytes = copied (bytes),
                refs = if refs ~= nil then table.clone (refs) else nil,
            })
        end

        return (self :: any) :: Transport
    end

    -- Everyone the frame is for: one client, the server, or the players in the game.
    local function audience (frame: Frame): { Side }
        if frame.from ~= nil then return { server } end
        if frame.to ~= nil then return { sideOf (frame.to) } end

        local every = {}
        for who, side in clients do
            if left[who] then continue end
            table.insert (every, side)
        end
        return every
    end

    local watchers: { (Carried) -> () } = {}

    local function handed (frame: Frame)
        for _, see in table.clone (watchers) do
            see (frame :: any)
        end

        for _, side in audience (frame) do
            local take = side.takes[frame.at]
            if take ~= nil then take (frame.from, frame.bytes, frame.refs) end
        end
    end

    local wire = {}

    --[[
        One round: whatever was held from the last one, then whatever was queued when this one
        opened, and nothing a handler queues while it runs. Answers how many frames it handed over,
        so a driver can pump to quiet.
    ]]
    function wire.deliver (): number
        local fresh = queued
        local late = holding
        queued = {}
        holding = {}

        local handled = 0

        --[[
            What was held is handed over now, unrolled: a frame held twice would be a lane that
            delays without bound, and holding once is the reorder.
        ]]
        for _, frame in late do
            handed (frame)
            handled += 1
        end

        for _, frame in fresh do
            if frame.at ~= LOSSY then
                handed (frame)
                handled += 1
                continue
            end

            local rolled = roll ()
            if rolled < faults.lose then
                tally.lost += 1
            elseif rolled < faults.lose + faults.double then
                tally.doubled += 1
                handed (frame)
                handed (frame)
                handled += 2
            elseif rolled < faults.lose + faults.double + faults.hold then
                tally.held += 1
                table.insert (holding, frame)
            else
                handed (frame)
                handled += 1
            end
        end
        return handled
    end

    -- Rounds until the wire goes quiet, answering how many it took.
    function wire.settle (): number
        local rounds = 0
        while #queued > 0 or #holding > 0 do
            rounds += 1
            wire.deliver ()
        end
        return rounds
    end

    --[[
        What crossed, counted by the wire rather than by the library. A suite asserting that nothing
        shipped cannot read that from the counters it is testing, so the lane keeps its own.
    ]]
    function wire.moved (): Moved return table.freeze (table.clone (tally)) end

    -- Somebody reading every frame this lane carries, and the way to stop.
    function wire.watch (_: any, see: (Carried) -> ()): () -> ()
        table.insert (watchers, see)

        return function ()
            local at = table.find (watchers, see)
            if at ~= nil then table.remove (watchers, at) end
        end
    end

    -- One frame handed to whoever it names, without anybody having sent it.
    function wire.hands (_: any, of: Carried) handed (of :: any) end

    -- A player out of the game, which a broadcast stops reaching from here on.
    function wire.gone (_: any, who: Player) left[who] = true end

    function wire.server (): Transport return endpoint (nil) end

    function wire.client (_: any, who: Player): Transport return endpoint (who) end

    return (wire :: any) :: Wire
end

--[[
    A roster of players that are not players. An engine makes no Player on demand, so each stub is
    an ordinary Instance under its label: `typeof` answers "Instance", it keys a table by identity,
    and it carries a name. Nothing else about a Player has a stand-in here, and a suite that needs
    more than identity and a name belongs in `live`.
]]
function Doubles.roster (): Roster
    local order: { Player } = {}
    local byLabel: { [string]: Player } = {}
    local added: { (Player) -> () } = {}
    local removing: { (Player) -> () } = {}

    local function subscribe (into: { (Player) -> () }, take: (Player) -> ()): () -> ()
        table.insert (into, take)
        return function ()
            local at = table.find (into, take)
            if at ~= nil then table.remove (into, at) end
        end
    end

    local roster = {}

    function roster.all (): { Player } return table.clone (order) end

    function roster.named (_: any, label: string): Player? return byLabel[label] end

    function roster.join (_: any, label: string): Player
        assert (byLabel[label] == nil, `{label} has already joined`)

        local stub = Instance.new (STAND_IN)
        stub.Name = label

        local who = (stub :: any) :: Player
        byLabel[label] = who
        table.insert (order, who)

        for _, take in table.clone (added) do
            take (who)
        end
        return who
    end

    function roster.leave (_: any, who: Player)
        local at = table.find (order, who)
        assert (at ~= nil, `{who.Name} is not on the roster`)

        table.remove (order, at)
        byLabel[who.Name] = nil

        for _, take in table.clone (removing) do
            take (who)
        end
    end

    function roster.onAdded (_: any, take: (Player) -> ()): () -> ()
        return subscribe (added, take) :: () -> ()
    end

    function roster.onRemoving (_: any, take: (Player) -> ()): () -> ()
        return subscribe (removing, take) :: () -> ()
    end

    return (roster :: any) :: Roster
end

-- One frame as the text a reading names it by, which is its lane and then its bytes.
function Doubles.dumped (of: Carried): string
    local out = table.create (buffer.len (of.bytes)) :: { string }
    for at = 0, buffer.len (of.bytes) - 1 do
        table.insert (out, string.format (DIGITS, buffer.readu8 (of.bytes, at)))
    end

    return `{of.at} {table.concat (out)}`
end

return table.freeze (Doubles)
