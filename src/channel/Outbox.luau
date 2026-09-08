--!strict
--!optimize 2
-- Everything queued, as the frames it becomes: one lane merged and ordered, one split and lost.

local Blocks = require("./Blocks")
local Link = require("./Link")
local Log = require("../kernel/Log")
local Protocol = require("../wire/Protocol")
local Transport = require("./Transport")

local Outbox = {}

-- Constants -----------------------------------------------------------

local SURE: Transport.Channel = "reliable"
local LOSSY: Transport.Channel = "unreliable"

-- What one fire of the lossy lane carries, and the hard ceiling on any fire. The ceiling is a
-- tripwire rather than a budget: a frame that wide is a loop that forgot to flush.
local CAP = Protocol.UNRELIABLE_CAP
local CEILING = Protocol.MAX_FIRE

-- What a frame that is everybody's is merged against, since it has no client half of its own.
local NONE = table.freeze({} :: { Blocks.Block })

-- Types ---------------------------------------------------------------

-- One client's own buckets, or nothing where the frame being assembled is everybody's.
type Mine = { { Blocks.Block } }?

-- Private -------------------------------------------------------------

-- What a frame comes to, and whether anything in it carries an instance.
local function summed(of: Link.Link, mine: Mine): (number, boolean)
    local bytes, carried = 0, false
    for class = 1, Blocks.CLASSES do
        for _, block in of.shared[class] do
            bytes += block.len
            if block.refs ~= nil then carried = true end
        end
        if mine == nil then continue end
        for _, block in mine[class] do
            bytes += block.len
            if block.refs ~= nil then carried = true end
        end
    end
    return bytes, carried
end

-- One frame: class by class, the shared and the client's own blocks merged by sequence.
local function assembled(
    of: Link.Link,
    mine: Mine,
    bytes: number,
    carried: boolean
): (buffer, Transport.Sidecar?)
    local frame = buffer.create(bytes)
    local side: Transport.Sidecar? = if carried then {} else nil
    local at = 0
    for class = 1, Blocks.CLASSES do
        local ours = of.shared[class]
        local theirs = if mine == nil then NONE else mine[class]
        local one, also = 1, 1
        while one <= #ours or also <= #theirs do
            local block
            if also > #theirs or (one <= #ours and ours[one].seq < theirs[also].seq) then
                block = ours[one]
                one += 1
            else
                block = theirs[also]
                also += 1
            end
            buffer.copy(frame, at, block.buf, 0, block.len)
            at += block.len
            local refs = block.refs
            if side ~= nil and refs ~= nil then table.insert(side, refs) end
        end
    end
    return frame, side
end

-- Whether any client has anything of their own queued.
local function diverges(of: Link.Link): boolean
    for _, buckets in of.divergent do
        for class = 1, Blocks.CLASSES do
            if #buckets[class] > 0 then return true end
        end
    end
    return false
end

-- One reliable frame, assembled and gone.
local function sent(of: Link.Link, mine: Mine, to: Player?)
    local bytes, carried = summed(of, mine)
    if bytes == 0 then return end
    if bytes > CEILING then
        local said =
            `{of.name} assembled a frame of {bytes} bytes, past the {CEILING} one fire takes`
        Log.error(said, { namespace = of.name })
    end
    local frame, side = assembled(of, mine, bytes, carried)
    of.transport:fire(SURE, to, frame, side)
end

-- The holds a block needs for an audience of that many, and whether there is anyone at all.
local function reaches(block: Blocks.Block, count: number): boolean
    if count == 0 then
        Blocks.release(block)
        return false
    end
    for _ = 2, count do
        Blocks.retain(block)
    end
    return true
end

-- Everything queued on the reliable lane out, one frame per client where any client has blocks
-- of their own and one for everybody where none does, then every bucket emptied.
local function reliable(of: Link.Link)
    if of.isServer and diverges(of) then
        for player in of.ready do
            sent(of, of.divergent[player], player)
        end
    else
        sent(of, nil, nil)
    end
    for class = 1, Blocks.CLASSES do
        Blocks.drain(of.shared[class])
    end
    for _, buckets in of.divergent do
        for class = 1, Blocks.CLASSES do
            Blocks.drain(buckets[class])
        end
    end
end

-- One lossy frame, from a run of blocks that fit inside the cap.
local function posted(
    of: Link.Link,
    held: { Blocks.Block },
    from: number,
    upto: number,
    bytes: number,
    at: Player?
)
    if bytes == 0 then return end
    local frame = buffer.create(bytes)
    local side: Transport.Sidecar? = nil
    local pos = 0
    for index = from, upto do
        local block = held[index]
        buffer.copy(frame, pos, block.buf, 0, block.len)
        pos += block.len
        local refs = block.refs
        if refs == nil then continue end
        if side == nil then
            side = { refs }
        else
            table.insert(side, refs)
        end
    end
    of.transport:fire(LOSSY, at, frame, side)
end

-- One queue of lossy blocks, as the fires it splits into.
local function looses(of: Link.Link, held: { Blocks.Block }, at: Player?)
    local from, bytes = 1, 0
    for index, block in held do
        if bytes + block.len > CAP then
            posted(of, held, from, index - 1, bytes, at)
            from, bytes = index, 0
        end
        bytes += block.len
    end
    posted(of, held, from, #held, bytes, at)
end

-- Everything queued on the lossy lane out, and the queues left empty.
local function lossy(of: Link.Link)
    looses(of, of.sharedLossy, nil)
    Blocks.drain(of.sharedLossy)
    for player, held in of.divergentLossy do
        looses(of, held, player)
        Blocks.drain(held)
    end
end

-- Public --------------------------------------------------------------

-- A block everybody gets, in the bucket its class drains in.
function Outbox.shared(of: Link.Link, block: Blocks.Block)
    table.insert(of.shared[block.class], block)
end

-- A block some of them get, in each of their own buckets.
function Outbox.targeted(of: Link.Link, to: { Player }, count: number, block: Blocks.Block)
    if not reaches(block, count) then return end
    for index = 1, count do
        table.insert(of.divergent[to[index]][block.class], block)
    end
end

-- A block everybody gets on the lane that may lose it.
function Outbox.loose(of: Link.Link, block: Blocks.Block)
    table.insert(of.sharedLossy, block)
end

-- A block some of them get on the lane that may lose it.
function Outbox.looseTo(of: Link.Link, to: { Player }, count: number, block: Blocks.Block)
    if not reaches(block, count) then return end
    for index = 1, count do
        table.insert(of.divergentLossy[to[index]], block)
    end
end

-- Both lanes out, and the flush over.
function Outbox.fire(of: Link.Link)
    if not of.sending then return end
    reliable(of)
    lossy(of)
    Link.rewind(of)
end

return table.freeze(Outbox)
