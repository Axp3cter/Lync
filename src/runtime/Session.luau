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
local Varint = require ("@src/wire/Varint")

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

--[[
    What a run of blocks is a run of. A question carries an id and an answer an outcome beside it,
    so the three cannot share a header even where they share a lane, and the one pending slot has
    to say which of them it is holding.
]]
const FIRES = 1
const ASKS = FIRES + 1
const ANSWERS = ASKS + 1

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

    -- The numbers a question and an answer carry, which their block's header no longer does.
    asked: { number },
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

-- Whether a block belongs to the run already open, which is one definition aimed at one audience.
local function joins (
    link: Link.Link,
    kind: number,
    def: any,
    to: Types.Recipient?,
    loose: boolean
): boolean
    if link.holds == 0 then return true end

    return link.kind == kind and link.over == def and link.toward == to and link.lossy == loose
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
    Tally.sent (self.counts, def.name, 0)

    -- The same climb the questions are held to, since these are written the same way back.
    if not joins (link, ANSWERS, def, who, false) or asked <= link.last then
        Session.shipped (self)
    end

    if link.holds == 0 then
        link.kind = ANSWERS
        link.over = def
        link.toward = who
        link.lossy = false
        link.wrote = def.answers.bytes
    end

    --[[
        Which question this answers and whether it is one, written beside the answer rather than in
        the block's header, so a run of them shares the header and nothing else. The first says the
        question whole and the rest say the step, with the one bit folded into the step's own.
    ]]
    local outcome = if ok then 0 else 1
    local ends

    if link.holds == 0 then
        local told = self.asked
        told[1] = asked
        told[2] = outcome
        def.answering.write (link.pending, link.wrote, told)

        ends = link.wrote + def.answering.bytes
    else
        ends = Varint.writeFlagged (link.pending, link.wrote, asked - link.last, outcome)
    end

    link.last = asked
    if ok then ends = def.response.write (link.pending, ends, value) end

    link.wrote = ends
    link.holds += 1

    if link.holds == def.answers.runs or link.wrote + def.response.maxBytes > link.room then
        Session.shipped (self)
    end
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
        asked = table.create (2, 0) :: { number },
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
    -- Whatever a caller fired and this flush is for, before anything is decided about the rest.
    Session.shipped (self)

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

--[[
    One block queued at whoever it was aimed at, and counted. A fire at nobody is counted as a fire
    and not as bytes, since what a caller wants from the tally is whether their audience was empty
    rather than whether the library did the writing.
]]
local function posted (
    self: Self,
    def: Compile.Packet,
    to: Types.Recipient?,
    loose: boolean,
    block: Blocks.Block
)
    local link = self.link

    if to == nil then
        if loose then
            Outbox.loose (link, block)
        else
            Outbox.shared (link, block)
        end

        Tally.carried (self.counts, def.name, block.len)
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

    if reach > 0 then Tally.carried (self.counts, def.name, block.len) end
end

-- One block written on its own, which is every fire a run cannot take.
local function alone (
    self: Self,
    def: Compile.Packet,
    to: Types.Recipient?,
    loose: boolean,
    ends: number
)
    local link = self.link
    local side = def.built.sidecar
    local held = if side.bears then side.refs else nil
    local class = if loose then Blocks.LOOSE else Blocks.PACKET
    local block = Blocks.sealed (link.scratch, ends, class, Link.next (link), held)

    table.clear (side.refs)
    table.clear (side.slotOf)

    Session.queued (self, def.name)
    posted (self, def, to, loose, block)
end

--[[
    Whatever run is still open, sealed and queued. Its header is written last, since what it states
    is how many payloads came after it and that is not known until no more are coming. Anything
    else wanting the lane calls this first, so a block never overtakes the fires that opened it.
]]
function Session.shipped (self: Self)
    local link = self.link
    if link.holds == 0 then return end

    local kind = link.kind
    local def = link.over :: any

    local head = if kind == FIRES then def.head elseif kind == ASKS then def.asks else def.answers

    local fields = self.fields
    fields[WHOSE] = if kind == ANSWERS then def.id + 1 else def.id
    fields[WHOSE + 1] = link.holds - 1
    head.write (link.pending, 0, fields)

    local built = if kind == FIRES
        then def.built
        elseif kind == ASKS then def.request
        else def.response

    local class = if kind == ASKS
        then Blocks.REQUEST
        elseif kind == ANSWERS then Blocks.RESPONSE
        elseif link.lossy then Blocks.LOOSE
        else Blocks.PACKET

    local side = built.sidecar
    local held = if side.bears then side.refs else nil
    local block = Blocks.sealed (link.pending, link.wrote, class, Link.next (link), held)

    table.clear (side.refs)
    table.clear (side.slotOf)

    local to = link.toward
    local loose = link.lossy

    link.holds = 0
    link.kind = 0
    link.over = nil
    link.toward = nil
    link.last = 0

    --[[
        A question and an answer go to exactly whoever they name, where a fire may name an audience
        and a broadcast names none. The two are one call apart, so the queue they land in is what
        the kind decides and everything before it is the same.
    ]]
    if kind == FIRES then
        posted (self, def, to, loose, block)
        return
    end

    Tally.carried (self.counts, def.name, block.len)
    if to == nil then
        Outbox.shared (link, block)
        return
    end

    local audience = link.audience
    audience[1] = to :: Player
    Outbox.targeted (link, audience, 1, block)
end

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

    --[[
        The fire counted here and its bytes where the block is sealed, because a run is many fires
        and one block. A caller reading the tally is asking how often they fired, which the sealing
        cannot answer and the firing cannot price.
    ]]
    Tally.sent (self.counts, def.name, 0)

    local link = self.link
    local loose = def.delivery ~= ORDERED

    --[[
        A definition that declared an instant is written one block a fire, because the instant is a
        field of the header and a run carries one header. Everything else opens a run, or joins the
        one already open where it is for the same definition and the same audience.
    ]]
    if def.timestamped then
        Session.shipped (self)

        local scratch = link.scratch
        local fields = self.fields
        fields[WHOSE] = def.id
        fields[WHOSE + 1] = Clock.stamp (Clock.elapsed (reading (), self.router.epoch))

        def.head.write (scratch, 0, fields)
        alone (self, def, to, loose, def.built.write (scratch, def.head.bytes, value))
        return
    end

    if not joins (link, FIRES, def, to, loose) then Session.shipped (self) end

    if link.holds == 0 then
        link.kind = FIRES
        link.over = def
        link.toward = to :: Player?
        link.lossy = loose
        link.wrote = def.head.bytes
    end

    link.wrote = def.built.write (link.pending, link.wrote, value)
    link.holds += 1

    Session.queued (self, def.name)
    if link.holds == def.head.runs or link.wrote + def.built.maxBytes > link.room then
        Session.shipped (self)
    end
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
    Tally.sent (self.counts, def.name, 0)

    -- A run's ids climb, so one that does not opens a block of its own rather than stepping back.
    if not joins (link, ASKS, def, to, false) or id <= link.last then Session.shipped (self) end

    local opening = link.holds == 0
    if opening then
        link.kind = ASKS
        link.over = def
        link.toward = to
        link.lossy = false
        link.wrote = def.asks.bytes
    end

    --[[
        The id belongs to the question rather than to the block, so it is written beside its own
        payload. Whole for the first of a run and the step from the last for every one after, since
        ids are handed out by climbing and a burst of them climbs by one.
    ]]
    if link.holds == 0 then
        self.asked[1] = id
        def.asking.write (link.pending, link.wrote, self.asked)
        link.wrote += def.asking.bytes
    else
        link.wrote = Varint.write (link.pending, link.wrote, id - link.last)
    end

    link.last = id
    link.wrote = def.request.write (link.pending, link.wrote, value)
    link.holds += 1

    Session.queued (self, def.name)

    if link.holds == def.asks.runs or link.wrote + def.request.maxBytes > link.room then
        Session.shipped (self)
    end
end

-- What this namespace has done, as the reading two of which subtract into a rate.
function Session.stats (self: Self): Types.Stats return Tally.reading (self.counts) end

return table.freeze (Session)
