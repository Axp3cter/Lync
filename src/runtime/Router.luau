--!strict
--!optimize 2
-- One frame taken apart: which definition each block is, and where that definition sends it.

local Boundary = require ("@src/runtime/Boundary")
local Catalog = require ("@src/kernel/Catalog")
local Clock = require ("@src/wire/Clock")
local Compile = require ("@src/shape/Compile")
local Dispatch = require ("@src/runtime/Dispatch")
local Frames = require ("@src/shape/Frames")
local Ir = require ("@src/shape/Ir")
local Pending = require ("@src/runtime/Pending")
local Protocol = require ("@src/wire/Protocol")
local Sequence = require ("@src/wire/Sequence")
local Serial = require ("@src/shape/Serial")
local Tally = require ("@src/kernel/Tally")
local Transport = require ("@src/channel/Transport")
local Types = require ("@src/Types")

local Router = {}

-- Constants -----------------------------------------------------------

-- Where a header's fields land in the one array every form is read into.
const WHOSE = 1
const SECOND = 2

-- What a response says about itself, which is a bit and is the only thing a failed one carries.
const ANSWERED = 0

-- The delivery a definition declares that puts it on the lane which may reorder and may lose.
const NEWEST: Serial.Delivery = "newest"

-- What a stamp counts in, which is what turns one back into seconds.
const RATE = Protocol.STAMP_RATE

--[[
    Why a request that reached nobody resolves the way it does.

    A responder that threw is the one case the wire has a bit for, and what the asking machine knows
    is that it will not be answered. It is not a timeout, since the answer arrived.
]]
const THREW: Types.OutcomeCode = "unanswered"

-- Types ---------------------------------------------------------------

-- One payload's reader, as everything this module refuses to know about it.
export type Take = (b: buffer, pos: number, ctx: Types.ValidateContext) -> (number, any)

-- The one definition this file names three times, and the two blocks it is.
type Query = Compile.Query

-- A responder's answer, handed over the moment the responder returned.
export type Answers = (def: Query, asked: number, player: Player?, ok: boolean, value: any) -> ()

-- Everything a frame is walked with, which is one namespace's worth and lasts as long as it does.
export type Wiring = {
    read space: Compile.Compiled,
    read tally: Tally.Tally,
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
    --[[
        Where a responder's answer goes, written after this is made because whatever queues one
        holds this and this holds it. The one field here that is not settled at construction, and it
        is settled before a frame can arrive: a namespace opens its lanes at start.
    ]]
    answered: Answers,

    -- The instant this namespace counts from, which every stamp on the wire is measured against.
    epoch: number,
}

-- Private -------------------------------------------------------------

-- The instances this block carries, moved where its reader looks them up.
local function paired (side: Ir.Sidecar, refs: Transport.Sidecar?, taken: number): number
    if not side.bears then return taken end

    local at = taken + 1
    local held = if type (refs) == "table" then refs[at] else nil

    table.clear (side.refs)

    -- A sender names this array, so anything that is not one leaves the block carrying none.
    if type (held) == "table" then table.move (held, 1, #held, 1, side.refs) end

    return at
end

-- Whether the frame still holds the header this block says it has.
local function holds (of: Wiring, head: Frames.Head, at: number, len: number, said: string): boolean
    if len - at >= head.bytes then return true end

    Boundary.lost (
        of.boundary,
        Catalog.BOUNDS,
        { said = `{said} wants {head.bytes} and has {len - at}` }
    )
    return false
end

-- Where one sender's newest packets have reached, made the first time one arrives from them.
local function latest (of: Wiring, from: Player): { [number]: number }
    local held = of.latest[from]
    if held ~= nil then return held end

    held = {}
    of.latest[from] = held
    return held
end

-- A stamp off the wire as the instant it was sent, on the clock both machines share.
local function stamped (of: Wiring, stamp: number): number
    local elapsed = Clock.elapsed (of.boundary.ctx.now, of.epoch)
    return of.epoch + Clock.unwrap (stamp, elapsed) / RATE
end

-- A packet block: one payload, or a run of them under one header.
local function packets (
    of: Wiring,
    def: Compile.Packet,
    from: Player?,
    b: buffer,
    at: number,
    len: number
): number?
    local head = def.head
    if not holds (of, head, at, len, def.name) then return nil end

    head.read (b, at, of.head)

    --[[
        Read once for the block rather than once a payload, since a run shares one header. The stamp
        is the send instant a caller compares across clients, and it reaches a listener beside the
        value because that is what the surface declares a listener takes.
    ]]
    local sent: number? = if def.timestamped then stamped (of, of.head[SECOND]) else nil

    --[[
        A block on the lane that reorders says where it is in the ring, and one that lost the race
        says nothing at all rather than something older than what this machine already has. The
        whole block goes, since a newest definition coalesces to one value before it is sequenced
        and a stale one is superseded whole.
    ]]
    local stale = false
    if def.delivery == NEWEST then
        local ring = of.head[head.fields]
        local seen = if from == nil then of.heardSeq else latest (of, from)
        local was = seen[def.id]

        stale = was ~= nil and not Sequence.isNewer (ring, was)
        if not stale then seen[def.id] = ring end
    end

    local pos = at + head.bytes
    local built = def.built

    while true do
        local ends, value = Boundary.ran (of.boundary, def, built, built.read, b, pos)
        if ends == nil then return nil end

        if not stale and of.boundary.took then
            if from == nil then
                Dispatch.packet (of.heard, def.id, def.name, value, sent)
            else
                Dispatch.packet (of.heard, def.id, def.name, value, from, sent)
            end
        end

        return ends
    end
end

-- A request block: one payload, and the answer it is owed put by for the next flush.
local function asked (
    of: Wiring,
    def: Query,
    from: Player?,
    b: buffer,
    at: number,
    len: number
): number?
    local head = def.asks
    if not holds (of, head, at, len, def.name) then return nil end

    head.read (b, at, of.head)

    local id = of.head[SECOND]
    local ends, value =
        Boundary.ran (of.boundary, def, def.request, def.request.read, b, at + head.bytes)
    if ends == nil then return nil end
    if not of.boundary.took then return ends end

    --[[
        The value first and who asked after it, and nothing after that on a client, which is what
        the surface declares a responder takes. A responder on a server is told who asked and one on
        a client has only ever been asked by the server, so there is nobody to name.
    ]]
    local ok, answer
    if from == nil then
        ok, answer = Dispatch.request (of.heard, def.id, value)
    else
        ok, answer = Dispatch.request (of.heard, def.id, value, from)
    end

    --[[
        Composed at once, so a responder answering something its own codec refuses raises on the
        line that returned it. A flush is as far from the responder as this machine can put that
        raise, and on one that never flushes again it lands nowhere at all.
    ]]
    of.answered (def, id, from, ok, answer)

    return ends
end

-- A response block: the id it answers, whether it was answered at all, and the payload if it was.
local function answered (
    of: Wiring,
    def: Query,
    b: buffer,
    at: number,
    len: number,
    now: number
): number?
    local head = def.answers
    if not holds (of, head, at, len, def.name) then return nil end

    head.read (b, at, of.head)

    local id = of.head[SECOND]
    local pos = at + head.bytes

    if of.head[head.fields] ~= ANSWERED then
        of.pending:fail (id, THREW, now)
        return pos
    end

    local ends, value = Boundary.ran (of.boundary, def, def.response, def.response.read, b, pos)
    if ends == nil then return nil end
    if of.boundary.took then of.pending:answer (id, value) end

    return ends
end

-- A state block, on whichever lane it arrived.
local function stated (of: Wiring, def: Compile.Set, lossy: boolean, b: buffer, at: number): number?
    local take = if lossy then of.streams[def.id] else of.sections[def.id]
    if take == nil then
        Boundary.lost (of.boundary, Catalog.DEFID, {
            expected = "a definition this endpoint holds a set for",
            got = def.name,
        })
        return nil
    end

    local ends = Boundary.ran (of.boundary, def, def.site, take, b, at)
    return ends
end

-- Public --------------------------------------------------------------

-- Everything one namespace's frames are walked with.
function Router.wiring (
    space: Compile.Compiled,
    boundary: Boundary.Boundary,
    heard: Dispatch.Wiring,
    pending: Pending.Pending,
    tally: Tally.Tally
): Wiring
    return {
        space = space,
        tally = tally,
        answered = function () end,
        naming = Frames.naming (space.count),
        into = { 0 },
        head = { 0, 0, 0 },
        boundary = boundary,
        heard = heard,
        pending = pending,
        sections = {},
        streams = {},
        latest = {},
        heardSeq = {},
        epoch = 0,
    }
end

-- One frame, taken apart into the blocks it is and each of them handed where it goes.
function Router.frame (
    of: Wiring,
    from: Player?,
    lossy: boolean,
    b: buffer,
    refs: Transport.Sidecar?,
    now: number
)
    local boundary = of.boundary
    Boundary.opened (boundary, from, now)

    local len = buffer.len (b)
    local naming = of.naming

    local at = 0
    local taken = 0

    while boundary.live and at < len do
        if len - at < naming.bytes then
            Boundary.lost (boundary, Catalog.DEFID, {
                expected = `a block of at least {naming.bytes} bytes`,
                got = `{len - at} left`,
            })
            return
        end

        naming.read (b, at, of.into)

        local id = of.into[WHOSE]
        local def = of.space.byId[id]

        if def == nil then
            Boundary.lost (boundary, Catalog.DEFID, {
                expected = `a definition of {of.space.space}`,
                got = tostring (id),
            })
            return
        end

        Boundary.stamped (boundary, from, id, now)

        local ends: number?
        if def.kind == "packet" then
            taken = paired (def.built.sidecar, refs, taken)
            ends = packets (of, def, from, b, at, len)
        elseif def.kind == "set" then
            taken = paired (def.site.sidecar, refs, taken)
            ends = stated (of, def, lossy, b, at)
        elseif id == def.id then
            taken = paired (def.request.sidecar, refs, taken)
            ends = asked (of, def, from, b, at, len)
        else
            taken = paired (def.response.sidecar, refs, taken)
            ends = answered (of, def, b, at, len, now)
        end

        if ends == nil then return end
        if ends <= at then
            Boundary.lost (boundary, Catalog.DEFID, {
                expected = "a block that reads forward",
                got = def.name,
            })
            return
        end

        Tally.received (of.tally, def.name, ends - at)
        at = ends
    end
end

return table.freeze (Router)
