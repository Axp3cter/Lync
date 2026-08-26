--!strict
--!optimize 2
-- One namespace, composed: everything under it wired together and driven from one place.

local Blocks = require ("@src/channel/Blocks")
local Boundary = require ("@src/runtime/Boundary")
local Catalog = require ("@src/kernel/Catalog")
local Catchup = require ("@src/state/Catchup")
local Clock = require ("@src/wire/Clock")
local Compile = require ("@src/shape/Compile")
local Dispatch = require ("@src/runtime/Dispatch")
local Group = require ("@src/channel/Group")
local Handles = require ("@src/runtime/Handles")
local Handshake = require ("@src/runtime/Handshake")
local Link = require ("@src/channel/Link")
local Log = require ("@src/kernel/Log")
local Outbox = require ("@src/channel/Outbox")
local Pending = require ("@src/runtime/Pending")
local Plan = require ("@src/state/Plan")
local Protocol = require ("@src/wire/Protocol")
local Recipients = require ("@src/channel/Recipients")
local Router = require ("@src/runtime/Router")
local Sections = require ("@src/state/Sections")
local Sequence = require ("@src/wire/Sequence")
local Serial = require ("@src/shape/Serial")
local Sync = require ("@src/state/Sync")
local Tally = require ("@src/kernel/Tally")
local Transport = require ("@src/channel/Transport")
local Types = require ("@src/Types")

local Session = {}
Session.__index = Session

-- Constants -----------------------------------------------------------

const HANDSHAKE: Transport.Channel = "handshake"
const RELIABLE: Transport.Channel = "reliable"
const UNRELIABLE: Transport.Channel = "unreliable"

-- What a definition declares about its lane, which decides the class its block takes.
const ORDERED: Serial.Delivery = "reliable"
const LATEST: Serial.Delivery = "newest"

-- The field a header opens with, which is the definition it is about, in every form there is.
const WHOSE = 1

const FLOOR = Protocol.BUDGET_FLOOR
const RATE = Protocol.BUDGET_RATE
const WINDOW = Protocol.DETECTOR_WINDOW

-- Types ---------------------------------------------------------------

-- Who is here, as the three things a namespace asks of the roster and no more.
export type Roster = {
    read all: (self: Roster) -> { Player },
    read onAdded: (self: Roster, take: (Player) -> ()) -> () -> (),
    read onRemoving: (self: Roster, take: (Player) -> ()) -> () -> (),
}

export type Session = {
    read started: boolean,
    read closed: boolean,
    read start: (self: Session) -> (),
    read queued: (self: Session, said: string) -> (),
    read listen: (self: Session, id: number, fn: (...any) -> ()) -> Types.Connection,
    read respond: (self: Session, id: number, name: string, fn: Dispatch.Responder) -> (),
    read fire: (self: Session, def: Compile.Packet, to: Types.Recipient?, value: any) -> (),
    read ask: (
        self: Session,
        def: Compile.Query,
        to: Player?,
        value: any,
        timeout: number?,
        complete: Types.Outcome<any>
    ) -> (),
    read set: (self: Session, id: number) -> Sync.Sync,
    read flush: (self: Session, budget: number?) -> (),
    read close: (self: Session) -> (),
    read stats: (self: Session) -> Types.Stats,
}

--[[
    What one namespace is. `order` is the set definitions by id, kept as a list because a table walk
    has no order and two machines planning in different orders would put a frame's blocks in
    different places. `purse` is what the shared stream spent on each client this flush, and
    `fields` is as wide as the widest header.
]]
type Self = {
    space: Compile.Compiled,
    isServer: boolean,
    transport: Transport.Transport,
    roster: Roster,
    link: Link.Link,
    boundary: Boundary.Boundary,
    heard: Dispatch.Wiring,
    pending: Pending.Pending,
    router: Router.Wiring,
    sets: { [number]: Sync.Sync },
    order: { number },
    rings: { [number]: number },
    newest: { number },
    latest: { [number]: Latest },
    reserve: number,
    purse: { [Player]: number },
    one: { Player },
    fields: { number },
    unhook: { () -> () },
    started: boolean,
    closed: boolean,
    at: number,
    armed: number?,
    owed: string?,
    counts: Tally.Tally,
    plan: Plan.Budget,
}

-- One newest packet, between the fires it took and the one transmission they come to.
type Latest = {
    held: boolean,
    value: any,
    to: Types.Recipient?,
    sent: string?,
    at: number,
}

-- Private -------------------------------------------------------------

-- The clock a stamp is measured against, which is the one both machines can read.
local function reading (): number return workspace:GetServerTimeNow () end

-- What one flush may spend on state per client.
local function budgeted (self: Self, asked: number?, now: number): number
    if asked ~= nil then
        if asked < FLOOR then
            Log.error (
                `a flush of {asked} bytes is under the floor of {FLOOR}`,
                { definition = self.space.space }
            )
        end
        return asked
    end

    local since = math.max (now - self.at, 0)
    return math.max (math.floor (RATE * since), FLOOR)
end

-- Whether anything in this namespace is catching up, which is what the shared plan reserves for.
local function owing (self: Self): boolean
    for _, id in self.order do
        if Sync.owing (self.sets[id]) then return true end
    end
    return false
end

-- One responder's answer, as the block that carries it.
local function replying (
    self: Self,
    def: Compile.Query,
    asked: number,
    who: Player?,
    ok: boolean,
    value: any
)
    local link = self.link
    local scratch = link.scratch
    local head = def.answers

    head.write (scratch, 0, { def.id + 1, asked, if ok then 0 else 1 })

    local ends = head.bytes
    if ok then ends = def.response.write (scratch, ends, value) end

    local side = def.response.sidecar
    local held = if side.bears then side.refs else nil
    local block = Blocks.sealed (scratch, ends, Blocks.RESPONSE, Link.next (link), held)
    Tally.sent (self.counts, def.name, block.len)

    table.clear (side.refs)
    table.clear (side.slotOf)

    if who == nil then
        Outbox.shared (link, block)
        return
    end

    local one = self.one
    one[1] = who
    Outbox.targeted (link, one, 1, block)
end

-- What each client is behind on, cut against what the shared stream already spent on it.
local function behind (self: Self, target: number, purse: { [Player]: number })
    for who in self.link.ready do
        local room = target - (purse[who] or 0)
        if room <= 0 then continue end

        for _, id in self.order do
            local spent = Sync.behind (self.sets[id], self.link, who, room)
            room -= spent

            if room <= 0 then break end
        end
    end
end

-- A client this endpoint may now send to, and everything it is owed of what already exists.
local function admitted (self: Self, who: Player)
    Link.admit (self.link, who)

    for _, id in self.order do
        Sync.joined (self.sets[id], who, self.link.ready)
    end
end

-- One departure, and every place this namespace held anything keyed by that player.
local function departed (self: Self, who: Player)
    local now = reading ()

    -- Every group this player was in, thinned.
    Group.dropped (who)

    self.pending:rejectFor (who, now)
    Boundary.left (self.boundary, who)
    self.router.latest[who] = nil

    for _, id in self.order do
        Sync.left (self.sets[id], who)
    end

    Link.drop (self.link, who)
    self.purse[who] = nil
end

-- Every newest packet held this flush, as the one transmission each comes to.
local function latest (self: Self, now: number)
    local link = self.link
    local scratch = link.scratch

    for _, id in self.newest do
        local one = self.latest[id]
        if not one.held then continue end

        local def = self.space.byId[id] :: Compile.Packet
        local hz = def.hz
        if hz ~= nil and now - one.at < 1 / hz then continue end

        local head = def.head
        local ends = def.built.write (scratch, head.bytes, one.value)
        local payload = buffer.readstring (scratch, head.bytes, ends - head.bytes)

        local side = def.built.sidecar
        one.held, one.value = false, nil

        if payload == one.sent then
            table.clear (side.refs)
            table.clear (side.slotOf)
            continue
        end

        one.sent, one.at = payload, now

        local fields = self.fields
        fields[WHOSE] = def.id

        local at = 1
        if def.timestamped then
            at += 1
            fields[at] = Clock.stamp (Clock.elapsed (now, self.router.epoch))
        end

        local ring = Sequence.next (self.rings[id] or 0)
        self.rings[id] = ring

        at += 1
        fields[at] = ring

        head.write (scratch, 0, fields)

        local carried = if side.bears then side.refs else nil
        local block = Blocks.sealed (scratch, ends, Blocks.LOOSE, Link.next (link), carried)

        table.clear (side.refs)
        table.clear (side.slotOf)

        local to = one.to
        if to == nil then
            Outbox.loose (link, block)
            Tally.carried (self.counts, def.name, block.len)
            continue
        end

        local audience = link.audience
        Recipients.resolve (audience, to, link.ready)

        local reach = #audience
        Outbox.looseTo (link, audience, reach, block)
        if reach > 0 then Tally.carried (self.counts, def.name, block.len) end
    end
end

-- The first bytes queued while this endpoint may send, and the thread that says so if none go.
local function arming (self: Self, said: string)
    if self.armed ~= nil then return end

    self.armed = reading ()
    self.owed = said

    --[[
        Delayed rather than pooled. The pool is coroutines run now and put back after, and a thread
        parked for a window is the one thing it is not for: it would hold one out of the pile for as
        long as the window lasts and put it back having done nothing most times.
    ]]
    task.delay (WINDOW, function ()
        if self.armed == nil or self.closed then return end

        Log.error (
            `{self.space.space} queued {self.owed} and never flushed`,
            { definition = self.owed }
        )
    end)
end

-- One frame in, on whichever lane it arrived.
local function arrived (self: Self, lossy: boolean): Transport.Received
    return function (from: Player?, bytes: buffer, refs: Transport.Sidecar?)
        local counts = self.counts

        -- A frame this endpoint may not read yet, recorded rather than swallowed.
        if not self.link.sending then
            local facts: Log.Facts = { code = Catalog.UNREADY }
            Log.warn (Log.line (Catalog.UNREADY, facts), facts)
            Tally.dropped (counts, nil)
            return
        end

        Tally.took (counts, buffer.len (bytes))
        Router.frame (self.router, from, lossy, bytes, refs, reading ())

        -- The frame over, which a receiver owes as much as a sender does.
        for _, id in self.order do
            Sync.settle (self.sets[id])
        end
    end
end

-- The handshake, from whichever end this is.
local function greeted (self: Self): Transport.Received
    if self.isServer then
        return function (from: Player?, bytes: buffer)
            local said, ok = Handshake.verdict (self.space.hash, self.router.epoch, bytes)
            if said == nil then return end

            self.transport:fire (HANDSHAKE, from, said)
            if ok and from ~= nil then admitted (self, from) end
        end
    end

    return function (_: Player?, bytes: buffer)
        local epoch = Handshake.judged (self.space.hash, bytes)
        if epoch == nil then return end

        self.router.epoch = epoch
        self.link.sending = true
        self.at = reading ()
    end
end

-- Public --------------------------------------------------------------

-- One namespace, compiled and wired, before anything is open.
function Session.new (
    space: string,
    defs: Types.Definitions,
    transport: Transport.Transport,
    roster: Roster,
    side: Transport.Side
): Session
    local compiled = Compile.build (space, defs)

    local sets: { [number]: Sync.Sync } = {}
    local order: { number } = {}
    local layouts: { Sections.Layout } = {}

    -- The widest thing one fire can put on the wire, which is what the scratch has to hold.
    local widest = Protocol.SECTION_BYTES
    local named = 0

    --[[
        The newest packets, and what each holds between the fires it takes and the one transmission
        they come to. Listed as well as keyed, because a flush walks them in the order the namespace
        named them and a table walk has no order.
    ]]
    local newest: { number } = {}
    local latest: { [number]: Latest } = {}

    for _, def in compiled.list do
        if def.kind == "packet" and def.delivery == LATEST then
            table.insert (newest, def.id)
            latest[def.id] = { held = false, value = nil, to = nil, sent = nil, at = 0 }
        end

        if def.kind == "packet" then
            named = math.max (named, def.head.fields)
        elseif def.kind == "query" then
            named = math.max (named, def.asks.fields, def.answers.fields)
        else
            named = math.max (named, def.head.fields, def.stream.fields)
        end

        if def.kind == "set" then continue end
        widest = math.max (widest, def.blockBytes)
    end

    for _, def in compiled.list do
        if def.kind ~= "set" then continue end

        local sync = Sync.new (def)
        local layout = sync.layout

        sets[def.id] = sync
        table.insert (order, def.id)
        table.insert (layouts, layout)

        widest = math.max (widest, layout.opening + layout.entry)
    end

    -- One tally for the namespace, held by everything that observes a number for it.
    local names = table.create (compiled.count) :: { string }
    for _, def in compiled.list do
        table.insert (names, def.name)
    end

    local counts = Tally.new (names)

    local link = Link.new (space, side, widest, transport, counts)
    local boundary = Boundary.new (space, counts)
    local heard = Dispatch.wiring ()
    local pending = Pending.new (space)
    local router = Router.wiring (compiled, boundary, heard, pending, counts)

    for _, id in order do
        local sync = sets[id]

        router.sections[id] = function (b, pos, ctx) return Sync.taken (sync, b, pos, ctx), nil end
        router.streams[id] = function (b, pos, ctx) return Sync.stream (sync, b, pos, ctx), nil end
    end

    local self: Self = {
        space = compiled,
        isServer = side == "server",
        transport = transport,
        roster = roster,
        link = link,
        boundary = boundary,
        heard = heard,
        pending = pending,
        router = router,
        sets = sets,
        order = order,
        rings = {},
        newest = newest,
        latest = latest,
        reserve = Catchup.reserve (layouts),
        purse = {},
        one = table.create (1) :: { Player },
        fields = table.create (named, 0) :: { number },
        unhook = {},
        started = false,
        closed = false,
        at = 0,
        armed = nil,
        owed = nil,
        counts = counts,
        plan = Plan.budget (0),
    }

    --[[
        Where a responder's answer goes, which is here and could not have been said sooner: the
        router is made before the session that queues through it, and the two hold each other.
    ]]
    router.answered = function (def, asked, who, ok, value)
        replying (self, def, asked, who, ok, value)
    end

    local held = (setmetatable (self, Session) :: any) :: Session

    -- Every handle bound to what this namespace compiled it into.
    for _, def in compiled.list do
        local of = (defs[def.name] :: any).live
        if of ~= nil then Handles.opened (of, def, held, side == "server") end
    end

    return held
end

-- The namespace opened, and whatever this end of it says first.
function Session.start (self: Self)
    if self.started then
        Log.error (`{self.space.space} has already started`, { definition = self.space.space })
    end
    self.started = true

    Link.open (self.link)

    self.transport:onReceive (HANDSHAKE, greeted (self))
    self.transport:onReceive (RELIABLE, arrived (self, false))
    self.transport:onReceive (UNRELIABLE, arrived (self, true))

    self.router.epoch = reading ()
    self.at = self.router.epoch

    if not self.isServer then
        self.transport:fire (HANDSHAKE, nil, Handshake.hello (self.space.hash))
        return
    end

    table.insert (
        self.unhook,
        self.roster:onRemoving (function (who: Player) departed (self, who) end)
    )

    for _, who in self.roster:all () do
        admitted (self, who)
    end
end

-- Everything buffered since the last flush, out.
function Session.flush (self: Self, budget: number?)
    local now = reading ()
    local target = budgeted (self, budget, now)

    if not self.link.sending then return end

    self.pending:sweep (now)
    latest (self, now)

    -- Every set's audiences, before anything is decided about what this flush carries.
    for _, id in self.order do
        Sync.resolved (self.sets[id], self.link, self.link.ready)
    end

    --[[
        The reserve comes off the shared plan and nothing puts it back. Held to the floor instead,
        the subtraction did nothing wherever the budget was near it, so a client catching up was
        left with whatever happened to be over. The floor is what a flush is given, not what the
        shared half of one is owed.
    ]]
    local held = if owing (self) then self.reserve else 0
    local plan = Plan.reset (self.plan, math.max (target - held, 0))

    local purse: { [Player]: number }? = nil
    if held > 0 then
        table.clear (self.purse)
        purse = self.purse
    end

    for _, id in self.order do
        Sync.shared (self.sets[id], self.link, plan, purse, self.link.ready, now)
    end

    if purse ~= nil then behind (self, target, purse) end

    Outbox.fire (self.link)

    for _, id in self.order do
        Sync.settle (self.sets[id])
    end

    Tally.flushed (self.counts)
    self.at = now
    self.armed = nil
    self.owed = nil
end

-- One last flush, everything outstanding told why, and the remotes let go.
function Session.close (self: Self)
    if self.closed then return end

    Session.flush (self)
    self.closed = true

    self.pending:rejectAll (reading ())

    for _, drop in self.unhook do
        drop ()
    end
    table.clear (self.unhook)

    -- One call, because a link closes what it speaks through and this handed it the one it has.
    Link.close (self.link)
end

-- Something queued, said by whoever queued it.
function Session.queued (self: Self, said: string)
    if not self.link.sending then return end
    arming (self, said)
end

-- A listener on a definition, and the connection that ends it.
function Session.listen (self: Self, id: number, fn: (...any) -> ()): Types.Connection
    return Dispatch.listen (self.heard, id, fn)
end

-- The one responder a query gets, refused at the second rather than at the reply.
function Session.respond (self: Self, id: number, name: string, fn: Dispatch.Responder)
    Dispatch.respond (self.heard, id, name, fn)
end

-- One set, by the id the wire names it under, which is what a handle mutates through.
function Session.set (self: Self, id: number): Sync.Sync return self.sets[id] end

-- One packet fired, as the block that carries it.
function Session.fire (self: Self, def: Compile.Packet, to: Types.Recipient?, value: any)
    -- A newest packet is held rather than written.
    if def.delivery == LATEST then
        local one = self.latest[def.id]
        one.held, one.value, one.to = true, value, to

        Session.queued (self, def.name)
        Tally.sent (self.counts, def.name, 0)
        return
    end

    local link = self.link
    local scratch = link.scratch
    local head = def.head

    local fields = self.fields
    fields[WHOSE] = def.id

    local at = 1
    if def.timestamped then
        at += 1
        fields[at] = Clock.stamp (Clock.elapsed (reading (), self.router.epoch))
    end

    head.write (scratch, 0, fields)

    local ends = def.built.write (scratch, head.bytes, value)

    local side = def.built.sidecar
    local held = if side.bears then side.refs else nil
    local loose = def.delivery ~= ORDERED
    local class = if loose then Blocks.LOOSE else Blocks.PACKET
    local block = Blocks.sealed (scratch, ends, class, Link.next (link), held)

    table.clear (side.refs)
    table.clear (side.slotOf)

    Session.queued (self, def.name)

    if to == nil then
        if loose then
            Outbox.loose (link, block)
        else
            Outbox.shared (link, block)
        end

        Tally.sent (self.counts, def.name, block.len)
        return
    end

    local audience = link.audience
    Recipients.resolve (audience, to, link.ready)

    local reach = #audience
    if loose then
        Outbox.looseTo (link, audience, reach, block)
    else
        Outbox.targeted (link, audience, reach, block)
    end

    -- A fire at nobody counted, and its bytes not.
    Tally.sent (self.counts, def.name, if reach > 0 then block.len else 0)
end

-- One question asked, and the answer put where whoever asked it will be told.
function Session.ask (
    self: Self,
    def: Compile.Query,
    to: Player?,
    value: any,
    timeout: number?,
    complete: Types.Outcome<any>
)
    local id = self.pending:open (reading (), def.name, to, timeout, complete)

    local link = self.link
    local scratch = link.scratch
    local head = def.asks

    local fields = self.fields
    fields[WHOSE] = def.id
    fields[WHOSE + 1] = id

    head.write (scratch, 0, fields)

    local ends = def.request.write (scratch, head.bytes, value)
    local side = def.request.sidecar
    local held = if side.bears then side.refs else nil
    local block = Blocks.sealed (scratch, ends, Blocks.REQUEST, Link.next (link), held)
    Tally.sent (self.counts, def.name, block.len)

    table.clear (side.refs)
    table.clear (side.slotOf)

    Session.queued (self, def.name)

    if to == nil then
        Outbox.shared (link, block)
        return
    end

    local audience = link.audience
    audience[1] = to
    Outbox.targeted (link, audience, 1, block)
end

-- What this namespace has done, as the reading two of which subtract into a rate.
function Session.stats (self: Self): Types.Stats return Tally.reading (self.counts) end

return table.freeze (Session)
