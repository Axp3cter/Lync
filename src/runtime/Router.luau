--!strict
--!optimize 2
-- One frame taken apart: which definition each block is, and where that definition sends it.

local Boundary = require("./Boundary")
local Catalog = require("../kernel/Catalog")
local Clock = require("../wire/Clock")
local Compile = require("../shape/Compile")
local Dispatch = require("./Dispatch")
local Frames = require("../shape/Frames")
local Ir = require("../shape/Ir")
local Pending = require("./Pending")
local Protocol = require("../wire/Protocol")
local Sequence = require("../wire/Sequence")
local Serial = require("../shape/Serial")
local Transport = require("../channel/Transport")
local Types = require("../Types")
local Varint = require("../wire/Varint")

local Router = {}

-- Constants -----------------------------------------------------------

-- Where a header's fields land in the one array every form is read into.
local WHOSE = 1
local SECOND = 2

-- The outcome bit where a response carries a value. A refusal carries the bit and nothing else.
local ANSWERED = 0

local NEWEST: Serial.Delivery = "newest"
local RATE = Protocol.STAMP_RATE

-- Why a request that reached nobody resolves the way it does: the answer arrived and said the
-- responder threw, so it is not a timeout.
local THREW: Types.OutcomeCode = "unanswered"

-- Types ---------------------------------------------------------------

export type Take = (b: buffer, pos: number, ctx: Types.ValidateContext) -> (number, any)

type Query = Compile.Query

-- A responder's answer, handed over the moment the responder returned.
export type Answers = (def: Query, asked: number, player: Player?, ok: boolean, value: any) -> ()

-- Everything a frame is walked with, one namespace's worth. `answered` is written after this is
-- made, since whatever queues an answer holds this and this holds it.
export type Wiring = {
    read space: Compile.Compiled,
    read naming: Frames.Head,
    read into: { number },
    read head: { number },
    read boundary: Boundary.Boundary,
    read heard: Dispatch.Wiring,
    read pending: Pending.Pending,
    read sections: { [number]: Take },
    read streams: { [number]: Take },
    read latest: { [Player]: { [number]: number } },
    read heardSeq: { [number]: number },
    answered: Answers,
    epoch: number,
}

-- Private -------------------------------------------------------------

-- The instances this block carries, moved where its reader looks them up. A sender names this
-- array, so anything that is not one leaves the block carrying none.
local function paired(side: Ir.Sidecar, refs: Transport.Sidecar?, taken: number): number
    if not side.bears then return taken end
    local at = taken + 1
    local held = if type(refs) == "table" then refs[at] else nil
    table.clear(side.refs)
    if type(held) == "table" then table.move(held, 1, #held, 1, side.refs) end
    return at
end

-- Whether the frame still holds the header this block says it has.
local function holds(of: Wiring, head: Frames.Head, at: number, len: number, said: string): boolean
    if len - at >= head.bytes then return true end
    local facts = { said = `{said} wants {head.bytes} and has {len - at}` }
    Boundary.lost(of.boundary, Catalog.BOUNDS, facts)
    return false
end

-- Where one sender's newest packets have reached, made the first time one arrives from them.
local function latest(of: Wiring, from: Player): { [number]: number }
    local held = of.latest[from]
    if held ~= nil then return held end
    held = {}
    of.latest[from] = held
    return held
end

-- A stamp off the wire as the instant it was sent, on the clock both machines share.
local function stamped(of: Wiring, stamp: number): number
    local elapsed = Clock.elapsed(of.boundary.ctx.now, of.epoch)
    return of.epoch + Clock.unwrap(stamp, elapsed) / RATE
end

-- Whether a newest block lost the race with one this machine already has, in which case the whole
-- block goes, since a newest definition coalesces to one value before it is sequenced.
local function stale(of: Wiring, def: Compile.Packet, from: Player?): boolean
    if def.delivery ~= NEWEST then return false end
    local ring = of.head[def.head.fields]
    local seen = if from == nil then of.heardSeq else latest(of, from)
    local was = seen[def.id]
    if was ~= nil and not Sequence.isNewer(ring, was) then return true end
    seen[def.id] = ring
    return false
end

-- A packet block: one payload, or a run of them under one header. A run is gathered before any is
-- handed over, into an array of its own since a listener parking partway along holds it.
local function packets(
    of: Wiring,
    def: Compile.Packet,
    from: Player?,
    b: buffer,
    at: number,
    len: number
): number?
    local head = def.head
    if not holds(of, head, at, len, def.name) then return nil end
    head.read(b, at, of.head)

    local sent: number? = if def.timestamped then stamped(of, of.head[SECOND]) else nil
    local skipped = stale(of, def, from)
    local pos = at + head.bytes
    local built = def.built
    local boundary = of.boundary

    -- Only a running form counts what follows. The other two carry one payload each.
    local held = if def.timestamped or def.delivery == NEWEST then 1 else of.head[SECOND] + 1
    if held == 1 then
        local ends, value = Boundary.ran(boundary, def, built, built.read, b, pos)
        if ends == nil then return nil end
        if not skipped and boundary.took then
            if from == nil then
                Dispatch.packet(of.heard, def.id, def.name, value, sent)
            else
                Dispatch.packet(of.heard, def.id, def.name, value, from, sent)
            end
        end
        return ends
    end

    local values = table.create(held)
    local taken = 0
    for _ = 1, held do
        local ends, value = Boundary.ran(boundary, def, built, built.read, b, pos)
        if ends == nil then return nil end
        if not skipped and boundary.took then
            taken += 1
            values[taken] = value
        end
        pos = ends
    end
    if taken > 0 then
        if from == nil then
            Dispatch.packets(of.heard, def.id, def.name, taken, values, sent)
        else
            Dispatch.packets(of.heard, def.id, def.name, taken, values, from, sent)
        end
    end
    return pos
end

-- A request block: each question's id, whole for the first and as the step climbed after, then
-- what it asks. Each answer is composed at once, so a responder answering something its own codec
-- refuses raises on the line that returned it.
local function asked(
    of: Wiring,
    def: Query,
    from: Player?,
    b: buffer,
    at: number,
    len: number
): number?
    local head = def.asks
    if not holds(of, head, at, len, def.name) then return nil end
    head.read(b, at, of.head)
    local held = of.head[SECOND] + 1
    local pos = at + head.bytes
    local boundary, request = of.boundary, def.request
    local id = 0

    for index = 1, held do
        if index == 1 then
            def.asking.read(b, pos, of.head)
            id = of.head[WHOSE]
            pos += def.asking.bytes
        else
            local step, after = Varint.read(b, pos)
            id += step
            pos = after
        end
        local ends, value = Boundary.ran(boundary, def, request, request.read, b, pos)
        if ends == nil then return nil end
        if boundary.took then
            local ok, answer
            if from == nil then
                ok, answer = Dispatch.request(of.heard, def.id, value)
            else
                ok, answer = Dispatch.request(of.heard, def.id, value, from)
            end
            of.answered(def, id, from, ok, answer)
        end
        pos = ends
    end
    return pos
end

-- A response block: which question each answers, whether it is one, and what it says, the bit
-- folded into the step after the first.
local function answered(
    of: Wiring,
    def: Query,
    b: buffer,
    at: number,
    len: number,
    now: number
): number?
    local head = def.answers
    if not holds(of, head, at, len, def.name) then return nil end
    head.read(b, at, of.head)
    local held = of.head[SECOND] + 1
    local pos = at + head.bytes
    local boundary, response, pending = of.boundary, def.response, of.pending
    local id = 0

    for index = 1, held do
        local outcome
        if index == 1 then
            def.answering.read(b, pos, of.head)
            id = of.head[WHOSE]
            outcome = of.head[def.answering.fields]
            pos += def.answering.bytes
        else
            local step, bit, after = Varint.readFlagged(b, pos)
            id += step
            outcome = bit
            pos = after
        end
        if outcome ~= ANSWERED then
            pending:fail(id, THREW, now)
            continue
        end
        local ends, value = Boundary.ran(boundary, def, response, response.read, b, pos)
        if ends == nil then return nil end
        if boundary.took then pending:answer(id, value) end
        pos = ends
    end
    return pos
end

-- A state block, on whichever lane it arrived.
local function stated(of: Wiring, def: Compile.Set, lossy: boolean, b: buffer, at: number): number?
    local take = if lossy then of.streams[def.id] else of.sections[def.id]
    if take == nil then
        Boundary.lost(of.boundary, Catalog.DEFID, {
            expected = "a definition this endpoint holds a set for",
            got = def.name,
        })
        return nil
    end
    return (Boundary.ran(of.boundary, def, def.site, take, b, at))
end

local function lost(of: Wiring, expected: string, got: string)
    Boundary.lost(of.boundary, Catalog.DEFID, { expected = expected, got = got })
end

-- Public --------------------------------------------------------------

function Router.wiring(
    space: Compile.Compiled,
    boundary: Boundary.Boundary,
    heard: Dispatch.Wiring,
    pending: Pending.Pending
): Wiring
    return {
        space = space,
        naming = Frames.naming(space.count),
        into = { 0 },
        head = { 0, 0, 0 },
        boundary = boundary,
        heard = heard,
        pending = pending,
        sections = {},
        streams = {},
        latest = {},
        heardSeq = {},
        answered = function() end,
        epoch = 0,
    }
end

-- One frame, block by block, stopping at the first block that does not read.
function Router.frame(
    of: Wiring,
    from: Player?,
    lossy: boolean,
    b: buffer,
    refs: Transport.Sidecar?,
    now: number
)
    local boundary = of.boundary
    Boundary.opened(boundary, from, now)
    local len = buffer.len(b)
    local naming = of.naming
    local at, taken = 0, 0

    while boundary.live and at < len do
        if len - at < naming.bytes then
            return lost(of, `a block of at least {naming.bytes} bytes`, `{len - at} left`)
        end
        naming.read(b, at, of.into)
        local id = of.into[WHOSE]
        local def = of.space.byId[id]
        if def == nil then return lost(of, `a definition of {of.space.space}`, tostring(id)) end
        Boundary.stamped(boundary, from, id, now)

        local ends: number?
        if def.kind == "packet" then
            taken = paired(def.built.sidecar, refs, taken)
            ends = packets(of, def, from, b, at, len)
        elseif def.kind == "set" then
            taken = paired(def.site.sidecar, refs, taken)
            ends = stated(of, def, lossy, b, at)
        elseif id == def.id then
            taken = paired(def.request.sidecar, refs, taken)
            ends = asked(of, def, from, b, at, len)
        else
            taken = paired(def.response.sidecar, refs, taken)
            ends = answered(of, def, b, at, len, now)
        end
        if ends == nil then return end
        if ends <= at then return lost(of, "a block that reads forward", def.name) end
        at = ends
    end
end

return table.freeze(Router)
