--!strict
--!optimize 2
-- The wire as Roblox runs it, where the plain double is kinder: a frame waits for a listener
-- rather than vanishing, every remote keeps an order of its own, the lossy remote loses, doubles,
-- reorders and refuses anything past its cap, and a player can go between any two frames.

local Doubles = require("@self/Doubles")
local Transport = require("@src/channel/Transport")

local Faithful = {}

-- Constants -----------------------------------------------------------

local LOSSY: Transport.Channel = "unreliable"

-- The engine's own threshold for one unreliable fire. Stated here rather than read off the
-- library, since this module stands in for the engine and the library is what it judges.
local CAP = 1000

-- The lane every reliable remote shares where the remotes are ordered together.
local ORDERED = "ordered"

-- What the server's side is sorted under, ahead of any player's name.
local SERVER = ""

-- Types ---------------------------------------------------------------

export type Channel = Transport.Channel
export type Transport = Transport.Transport

-- Whatever a seeded draw comes from. The test harness's generator is one.
export type Draw = {
    int: (self: any, min: number, max: number) -> number,
    bool: (self: any, chance: number?) -> boolean,
}

-- How the lossy remote misbehaves: a frame lost, a frame delivered twice, and how far from the
-- front of its queue a frame may be taken, which is one where nothing overtakes.
export type Faults = {
    read lose: number,
    read double: number,
    read reach: number,
}

-- `shared` puts both reliable remotes of one connection in one order, as an engine that orders
-- every reliable remote together would. `guard` names deliveries whose handler may raise, which
-- the wire then records on the frame rather than letting through. `said` hears a line for every
-- frame fired and handed over, for a trace that wants the wire's half of a story.
export type Options = {
    read draw: Draw,
    read roster: Doubles.Roster,
    read shared: boolean?,
    read faults: Faults?,
    read guard: ((frame: Frame, to: Player?) -> boolean)?,
    read said: ((line: string) -> ())?,
}

-- Where a fired frame ended up. `absent` is a frame aimed at a player who is not in the game.
export type Fate = "queued" | "lost" | "doubled" | "oversize" | "absent" | "nobody"

-- One frame as the wire recorded it. `from` is nothing for the server's own, and `to` is nothing
-- for a broadcast or for anything a client fired. `reached` is who it was queued for.
export type Frame = {
    read serial: number,
    read at: Channel,
    read from: Player?,
    read to: Player?,
    read bytes: any,
    read refs: any,
    read hostile: boolean,
    read reached: { Player },
    fate: Fate,
    delivered: number,
    raised: string?,
}

-- The wire, from either end, and everything it has carried.
export type Wire = {
    read server: (self: Wire) -> Transport,
    read client: (self: Wire, who: Player) -> Transport,
    read gone: (self: Wire, who: Player) -> (),
    read inject: (self: Wire, from: Player, at: Channel, bytes: any, refs: any) -> Frame,
    read step: (self: Wire) -> boolean,
    read deliver: (self: Wire, count: number, only: ((Frame, Player?) -> boolean)?) -> number,
    read settle: (self: Wire, between: (() -> ())?) -> number,
    read watch: (self: Wire, see: (Frame) -> ()) -> () -> (),
    read arrived: (self: Wire, see: (Frame, Player?) -> ()) -> () -> (),
    read frames: (self: Wire) -> { Frame },
    read fired: (self: Wire) -> number,
    read waiting: (self: Wire) -> number,
    read delivering: (self: Wire) -> (Frame?, Player?),
}

type Side = {
    takes: { [Channel]: Transport.Received },
    opened: boolean,
    gone: boolean,
}

-- One connection's frames in one direction on one lane, in the order the lane keeps them.
type Queue = {
    read dest: Player?,
    read src: Player?,
    read lane: string,
    read name: string,
    read items: { Frame },
}

type Choice = { queue: Queue, index: number }

-- Private -------------------------------------------------------------

-- A copy taken when the frame is fired, since the library reuses one frame buffer between fires.
local function copied(bytes: any): any
    if typeof(bytes) ~= "buffer" then return bytes end
    local size = buffer.len(bytes)
    local out = buffer.create(size)
    buffer.copy(out, 0, bytes, 0, size)
    return out
end

-- The sidecar as the engine serializes it: tables copied, instances passed by reference.
local function carried(value: any): any
    if type(value) ~= "table" then return value end
    local out = {}
    for key, held in value do
        out[key] = carried(held)
    end
    return out
end

local function named(who: Player?): string
    return if who == nil then SERVER else who.Name
end

local function earlier(a: Choice, b: Choice): boolean
    if a.queue.name ~= b.queue.name then return a.queue.name < b.queue.name end
    return a.index < b.index
end

-- Public --------------------------------------------------------------

-- A lossy remote that behaves, and one that does everything the engine allows it to.
Faithful.CALM = table.freeze({ lose = 0, double = 0, reach = 1 } :: Faults)
Faithful.ROUGH = table.freeze({ lose = 0.2, double = 0.1, reach = 3 } :: Faults)

Faithful.CAP = CAP

function Faithful.new(options: Options): Wire
    local draw = options.draw
    local roster = options.roster
    local shared = options.shared == true
    local faults = options.faults or Faithful.CALM
    local guard = options.guard
    local said = options.said

    local server: Side = { takes = {}, opened = false, gone = false }
    local clients: { [Player]: Side } = {}
    local queues: { [string]: Queue } = {}
    local log: { Frame } = {}
    local watchers: { (Frame) -> () } = {}
    local landing: { (Frame, Player?) -> () } = {}
    local fired = 0
    local current: Frame? = nil
    local currentTo: Player? = nil

    local function sideOf(who: Player?): Side
        if who == nil then return server end
        local held = clients[who]
        if held == nil then
            held = { takes = {}, opened = false, gone = false }
            clients[who] = held
        end
        return held
    end

    local function present(who: Player): boolean
        return not sideOf(who).gone and table.find(roster:all(), who) ~= nil
    end

    local function queueOf(dest: Player?, src: Player?, at: Channel): Queue
        local lane = if at == LOSSY then LOSSY elseif shared then ORDERED else at
        local name = `{named(dest)}<{named(src)}:{lane}`
        local held = queues[name]
        if held == nil then
            held = { dest = dest, src = src, lane = lane, name = name, items = {} }
            queues[name] = held
        end
        return held
    end

    -- One frame into one queue, the lossy lane rolling for it there and then.
    local function queued(frame: Frame, dest: Player?, src: Player?)
        local queue = queueOf(dest, src, frame.at)
        if frame.at == LOSSY and not frame.hostile then
            if faults.lose > 0 and draw:bool(faults.lose) then
                frame.fate = "lost"
                return
            end
            if faults.double > 0 and draw:bool(faults.double) then
                frame.fate = "doubled"
                table.insert(queue.items, frame)
            end
        end
        table.insert(queue.items, frame)
        table.insert(frame.reached, dest or (src :: Player))
    end

    local function recorded(at: Channel, from: Player?, to: Player?, bytes: any, refs: any): Frame
        local frame: Frame = {
            serial = #log + 1,
            at = at,
            from = from,
            to = to,
            bytes = bytes,
            refs = refs,
            hostile = false,
            reached = {},
            fate = "queued",
            delivered = 0,
            raised = nil,
        }
        table.insert(log, frame)
        return frame
    end

    -- A player out of the game: nothing more reaches them and nothing of theirs reaches anybody.
    local function left(who: Player)
        sideOf(who).gone = true
        for name, queue in queues do
            if queue.dest == who or queue.src == who then queues[name] = nil end
        end
    end
    roster:onRemoving(left)

    local function endpoint(owner: Player?): Transport
        local self = {}

        function self.open()
            sideOf(owner).opened = true
        end

        function self.close()
            local side = sideOf(owner)
            side.opened = false
            side.takes = {}
        end

        function self.onReceive(_: any, at: Channel, take: Transport.Received)
            sideOf(owner).takes[at] = take
        end

        function self.fire(_: any, at: Channel, to: Player?, bytes: buffer, refs: any)
            assert(sideOf(owner).opened, "a closed transport fired")
            assert(owner == nil or to == nil, "a client fired at a recipient")
            fired += 1
            local frame = recorded(at, owner, to, copied(bytes), carried(refs))
            if said ~= nil then
                local whom = if owner ~= nil then "server" elseif to ~= nil then to.Name else "all"
                said(`fire #{frame.serial} {at} {named(owner)}->{whom} {buffer.len(bytes)}B`)
            end
            for _, see in table.clone(watchers) do
                see(frame)
            end
            if at == LOSSY and buffer.len(bytes) > CAP then
                frame.fate = "oversize"
                return
            end
            if owner ~= nil then
                if not present(owner) then
                    frame.fate = "absent"
                    return
                end
                return queued(frame, nil, owner)
            end
            if to ~= nil then
                if not present(to) then
                    frame.fate = "absent"
                    return
                end
                return queued(frame, to, nil)
            end
            -- A broadcast reaches whoever is in the game when it is fired.
            local everyone = roster:all()
            if #everyone == 0 then frame.fate = "nobody" end
            for _, who in everyone do
                if not sideOf(who).gone then queued(frame, who, nil) end
            end
        end

        return (self :: any) :: Transport
    end

    -- Every frame that could be handed over now, in an order that does not depend on addresses.
    local function choices(only: ((Frame, Player?) -> boolean)?): { Choice }
        local out: { Choice } = {}
        for _, queue in queues do
            local items = queue.items
            if #items == 0 then continue end
            local side = sideOf(queue.dest)
            if side.gone then continue end
            local reach = if queue.lane == LOSSY then math.min(faults.reach, #items) else 1
            for index = 1, reach do
                local frame = items[index]
                if side.takes[frame.at] == nil then continue end
                if only ~= nil and not only(frame, queue.dest) then continue end
                table.insert(out, { queue = queue, index = index })
            end
        end
        table.sort(out, earlier)
        return out
    end

    local function handed(queue: Queue, index: number)
        local frame = table.remove(queue.items, index) :: Frame
        local to = queue.dest
        local take = sideOf(to).takes[frame.at]
        frame.delivered += 1
        if said ~= nil then said(`hand #{frame.serial} to {named(to)}`) end
        local was, wasTo = current, currentTo
        current, currentTo = frame, to
        for _, see in table.clone(landing) do
            see(frame, to)
        end
        -- A client's handler is told nothing about who sent it, as the engine's relay has it.
        local from = if to == nil then frame.from else nil
        if guard ~= nil and guard(frame, to) then
            local ok, thrown = pcall(take, from, frame.bytes, frame.refs)
            if not ok then frame.raised = tostring(thrown) end
        else
            take(from, frame.bytes, frame.refs)
        end
        current, currentTo = was, wasTo
    end

    local function stepped(only: ((Frame, Player?) -> boolean)?): boolean
        local open = choices(only)
        if #open == 0 then return false end
        local chosen = open[if #open == 1 then 1 else draw:int(1, #open)]
        handed(chosen.queue, chosen.index)
        return true
    end

    local wire = {}

    function wire.server(): Transport
        return endpoint(nil)
    end

    function wire.client(_: any, who: Player): Transport
        return endpoint(who)
    end

    -- A departure the roster has not been told about, for a case driving the wire alone.
    function wire.gone(_: any, who: Player)
        left(who)
    end

    -- A frame the attacker's own client sent, so it carries their real identity, and anything
    -- at all as its payload and its sidecar. Nothing about it is copied or rolled for.
    function wire.inject(_: any, from: Player, at: Channel, bytes: any, refs: any): Frame
        local frame = recorded(at, from, nil, bytes, refs);
        (frame :: any).hostile = true
        if not present(from) then
            frame.fate = "absent"
            return frame
        end
        queued(frame, nil, from)
        return frame
    end

    -- One frame handed over, chosen by the draw among everything that could be, or false where
    -- nothing can be.
    function wire.step(): boolean
        return stepped(nil)
    end

    -- Up to `count` frames, only those `only` allows where it is given, answering how many.
    function wire.deliver(_: any, count: number, only: ((Frame, Player?) -> boolean)?): number
        local handled = 0
        while handled < count and stepped(only) do
            handled += 1
        end
        return handled
    end

    -- Frames until nothing more can be handed over, with `between` run after each, which is
    -- where a player leaves between two frames.
    function wire.settle(_: any, between: (() -> ())?): number
        local handled = 0
        while stepped(nil) do
            handled += 1
            if between ~= nil then between() end
        end
        return handled
    end

    -- Somebody told of every frame as it is fired, before the wire does anything with it.
    function wire.watch(_: any, see: (Frame) -> ()): () -> ()
        table.insert(watchers, see)
        return function()
            local at = table.find(watchers, see)
            if at ~= nil then table.remove(watchers, at) end
        end
    end

    -- Somebody told of every frame as it is handed over, before its handler runs.
    function wire.arrived(_: any, see: (Frame, Player?) -> ()): () -> ()
        table.insert(landing, see)
        return function()
            local at = table.find(landing, see)
            if at ~= nil then table.remove(landing, at) end
        end
    end

    function wire.frames(): { Frame }
        return log
    end

    -- How many frames the library fired, which nothing injected counts toward.
    function wire.fired(): number
        return fired
    end

    -- Frames still queued anywhere, whether or not anybody is listening for them yet.
    function wire.waiting(): number
        local count = 0
        for _, queue in queues do
            count += #queue.items
        end
        return count
    end

    -- The frame being handed over right now and who to, for a watcher attributing what its
    -- handler says.
    function wire.delivering(): (Frame?, Player?)
        return current, currentTo
    end

    return (wire :: any) :: Wire
end

return table.freeze(Faithful)
