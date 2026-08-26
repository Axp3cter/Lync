--!strict
--!optimize 2
-- One set, coordinated: what a caller does to it, and what a flush turns that into.

local Apply = require ("@src/state/Apply")
local Audience = require ("@src/state/Audience")
local Blocks = require ("@src/channel/Blocks")
local Catchup = require ("@src/state/Catchup")
local Coalesce = require ("@src/state/Coalesce")
local Compile = require ("@src/shape/Compile")
local Link = require ("@src/channel/Link")
local Listeners = require ("@src/kernel/Listeners")
local Log = require ("@src/kernel/Log")
local Newest = require ("@src/state/Newest")
local Outbox = require ("@src/channel/Outbox")
local Plan = require ("@src/state/Plan")
local Protocol = require ("@src/wire/Protocol")
local Recipients = require ("@src/channel/Recipients")
local Sections = require ("@src/state/Sections")
local Store = require ("@src/state/Store")
local Tally = require ("@src/kernel/Tally")
local Types = require ("@src/Types")
local Wide = require ("@src/kernel/Wide")

local Sync = {}

-- Constants -----------------------------------------------------------

const KEYFRAME = Protocol.SECTION_KEYFRAME
const DELTA = Protocol.SECTION_DELTA
const REMOVAL = Protocol.SECTION_REMOVAL
const CLEAR = Protocol.SECTION_CLEAR

-- A record that has moved no field yet, which is what a first update is taken over.
const NOTHING = Wide.NONE

-- The partition an unkeyed set is the whole of.
const WHOLE = table.freeze ({})

-- What a caller writes into an update to empty a field, which nothing else can mean.
const CLEARED =
    setmetatable ({}, table.freeze ({ __tostring = function (): string return "Lync.none" end }))

-- Types ---------------------------------------------------------------

-- One partition: what it holds, what it owes the wire, and where its newest streams have reached.
export type Partition = {
    read key: any,
    read store: Store.Store,
    read dirt: Plan.Dirt,
    read streams: Newest.Streams,
}

-- One set, as everything that has to agree about it.
export type Sync = {
    read def: Compile.Set,
    read layout: Sections.Layout,
    read plan: Plan.Plan,
    read lane: Newest.Lane,
    read seen: Audience.Audience,
    read owed: Catchup.Catchup,
    read heard: Apply.Heard,
    read added: Listeners.List<number, any>,
    read changed: Listeners.List<number, any, any>,
    read removed: Listeners.List<number, Types.Cause>,
    read parts: { [any]: Partition },
    read order: { any },
    read partOf: { [number]: any },
    read place: { [string]: number },
    read climbs: boolean,
    read streams: boolean,
    read row: { any },
    read one: { Player },
    at: number,
}

-- Private -------------------------------------------------------------

-- What a partition is found under, which is a table key and so is never nothing.
local function under (key: any): any return if key == nil then WHOLE else key end

local function refuse (of: Sync, said: string, id: number): never
    return Log.error (`{of.def.name} {said} record {id}`, { definition = of.def.name })
end

-- An id a record can be held under, which is any whole number a double carries exactly.
local function identified (of: Sync, id: number)
    if id ~= id or id % 1 ~= 0 or math.abs (id) >= Protocol.EXACT then
        refuse (of, "cannot hold a record under", id)
    end
end

-- The partition a key names, made where this is the first record to name it.
local function partition (of: Sync, key: any): Partition
    local at = under (key)
    local held = of.parts[at]
    if held ~= nil then return held end

    local made: Partition = {
        key = key,
        store = Store.new (of.def),
        dirt = Plan.dirt (),
        streams = Newest.streams (of.lane),
    }

    of.parts[at] = made
    table.insert (of.order, at)
    return made
end

-- Every field of a record into the store, which is the whole of what a bind leaves to say.
local function written (of: Sync, store: Store.Store, slot: number, record: any)
    local names = of.def.fieldNames
    for field = 1, of.def.fieldCount do
        Store.write (store, slot, field, record[names[field]])
    end
end

-- A record marked as owing whatever it now owes, which is what the net of a flush is taken over.
local function marked (part: Partition, id: number, took: Coalesce.Kind)
    local dirt = part.dirt
    dirt.ops[id] = Coalesce.merge (dirt.ops[id], took)
end

-- A record taken out of a partition, and what that leaves the wire owing.
local function released (part: Partition, id: number, slot: number)
    local dirt = part.dirt

    dirt.masks[id] = nil
    dirt.ops[id] = Coalesce.merge (dirt.ops[id], "remove")

    if dirt.ops[id] == nil then
        Store.spare (part.store, slot)
        return
    end

    dirt.freed[slot] = id
end

-- One record out of the partition its key used to name, and into the one it names now.
local function migrated (of: Sync, from: Partition, id: number, slot: number)
    local row = of.row
    local columns = from.store.columns

    for field = 1, of.def.fieldCount do
        row[field] = columns[field][slot]
    end

    Store.unbind (from.store, id)
    released (from, id, slot)

    local into = partition (of, row[of.def.keyIndex :: number])
    local held = Store.bind (into.store, id)

    for field = 1, of.def.fieldCount do
        Store.write (into.store, held, field, row[field])
    end

    marked (into, id, "add")
    of.partOf[id] = under (into.key)
end

-- Ids a removal or a clear is about to take away, read while they can still be found.
local function losing (of: Sync, part: Partition, kind: number)
    if kind == CLEAR then
        for id in part.store.slotOf do
            of.partOf[id] = nil
        end
        return
    end

    if kind ~= REMOVAL then return end

    local frame = of.layout.frame
    local ids = part.store.ids

    for index = 1, frame.count do
        local id = ids[frame.slots[index]]
        if id ~= nil then of.partOf[id] = nil end
    end
end

-- Ids a keyframe has just bound, which is the only section that puts a record anywhere.
local function gaining (of: Sync, part: Partition, kind: number, at: any)
    if kind ~= KEYFRAME then return end

    local frame = of.layout.frame
    for index = 1, frame.count do
        of.partOf[frame.ids[index]] = at
    end
end

-- One block over the section just written, with whatever instances it named beside it.
local function sealed (of: Sync, link: Link.Link, len: number, class: number): Blocks.Block
    local side = of.def.site.sidecar

    --[[
        One where the schema can name an instance and nothing where it cannot, since that is the
        fact both machines pair a frame's sidecar by. Whether this payload named one is not it.
    ]]
    local held = if side.bears then side.refs else nil
    local made = Blocks.sealed (link.scratch, len, class, Link.next (link), held)
    Tally.sent (link.tally, of.def.name, len)

    table.clear (side.refs)
    table.clear (side.slotOf)
    return made
end

-- One section into the queue, everybody's or its audience's.
local function queued (of: Sync, link: Link.Link, at: any, open: boolean, kind: number, len: number)
    local block = sealed (of, link, len, if kind == DELTA then Blocks.DELTA else Blocks.ESTABLISH)

    if open then
        Outbox.shared (link, block)
        return
    end

    local now = Audience.members (of.seen, at)
    Outbox.targeted (link, now, #now, block)
end

-- What a shared section cost every client that is going to receive it.
local function billed (
    of: Sync,
    purse: { [Player]: number },
    at: any,
    open: boolean,
    ready: Recipients.Ready,
    bytes: number
)
    if open then
        for who in ready do
            purse[who] = (purse[who] or 0) + bytes
        end
        return
    end

    for _, who in Audience.members (of.seen, at) do
        purse[who] = (purse[who] or 0) + bytes
    end
end

-- Who sees this partition now, and what has changed about that since the last flush.
local function diffed (of: Sync, part: Partition, ready: Recipients.Ready): boolean
    local at = under (part.key)

    Audience.diff (of.seen, at, ready)

    local gained, lost = of.seen.gained, of.seen.lost
    if #gained > 0 then Catchup.gained (of.owed, at, gained, part.store) end
    if #lost > 0 then Catchup.lost (of.owed, at, lost) end

    return Audience.everyone (of.seen, at)
end

-- Every record a partition holds, gone, for the clients that stopped being able to see it.
local function withdrawn (of: Sync, link: Link.Link, part: Partition, lost: { Player })
    local store = part.store
    local frame = of.layout.frame
    local layout = of.layout

    -- A partition emptied this flush takes its losers with it, and says so in one section.
    if part.dirt.cleared then
        frame.key = part.key

        local ends = Sections.clear (layout, link.scratch, 0)
        Outbox.targeted (link, lost, #lost, sealed (of, link, ends, Blocks.ESTABLISH))
        return
    end

    --[[
        Every slot this client was actually holding, which is every one that shipped. A record added
        in the flush that took the key away has not been sent yet, so a removal for it would be a
        removal of something the client never had, and the pending operation says so.
    ]]
    local ops = part.dirt.ops
    local freed = part.dirt.freed
    local held = 0

    for slot = 1, store.high do
        local id = store.ids[slot]
        if id == nil then id = freed[slot] end
        if id == nil or ops[id] == "add" then continue end

        held += 1
        frame.slots[held] = slot
    end
    if held == 0 then return end

    frame.key = part.key

    local reach = Plan.keyframes (layout, Protocol.SECTION_BYTES)
    local from = 1

    while from <= held do
        local count = math.min (reach, held - from + 1)
        for index = 1, count do
            frame.slots[index] = frame.slots[from + index - 1]
        end

        frame.count = count
        local ends = Sections.removal (layout, link.scratch, 0)

        Outbox.targeted (link, lost, #lost, sealed (of, link, ends, Blocks.ESTABLISH))
        from += count
    end
end

-- Every partition's audience, worked out before the flush decides anything about itself.
function Sync.resolved (of: Sync, link: Link.Link, ready: Recipients.Ready)
    for _, at in of.order do
        local part = of.parts[at]
        diffed (of, part, ready)

        local lost = of.seen.lost
        if #lost > 0 then withdrawn (of, link, part, lost) end
    end
end

-- One partition's reliable sections, planned, queued, applied here and retired.
local function planned (
    of: Sync,
    link: Link.Link,
    budget: Plan.Budget,
    purse: { [Player]: number }?,
    part: Partition,
    open: boolean,
    ready: Recipients.Ready,
    opens: (Plan.Plan, Plan.Budget, Partition) -> boolean
)
    if not opens (of.plan, budget, part) then return end

    local frame = of.layout.frame
    local at = under (part.key)
    local scratch = link.scratch

    while true do
        local kind, ends = Plan.next (of.plan, budget, part, scratch, 0)
        if kind == nil then break end

        if kind == KEYFRAME or kind == REMOVAL then
            Catchup.retired (of.owed, at, frame.slots, 1, frame.count)
        elseif kind == CLEAR then
            Catchup.cleared (of.owed, at)
        end

        if kind ~= CLEAR then Apply.section (part.store, of.layout, kind, of.heard) end

        if kind == REMOVAL then
            for index = 1, frame.count do
                Store.spare (part.store, frame.slots[index])
            end
        end

        queued (of, link, at, open, kind, ends)
        if kind == KEYFRAME then
            Newest.established (of.lane, part.store, frame.slots, frame.count)
        end

        if purse ~= nil then billed (of, purse, at, open, ready, ends) end
    end
end

-- One partition's newest fields, each as much of its stream as one fire carries.
local function streamed (of: Sync, link: Link.Link, part: Partition, open: boolean, now: number)
    local lane = of.lane
    local reach = #lane.fields
    if reach == 0 then return end

    local streams = part.streams
    local store = part.store
    local scratch = link.scratch

    lane.key = part.key

    for at = 1, reach do
        local count = Newest.changed (lane, streams, store, at, now)
        if count == 0 then continue end

        local ends = Newest.section (lane, streams, store, at, scratch, 0, now, count)
        local block = sealed (of, link, ends, Blocks.LOOSE)

        if open then
            Outbox.loose (link, block)
            continue
        end

        local held = Audience.members (of.seen, under (part.key))
        Outbox.looseTo (link, held, #held, block)
    end
end

-- The record an id names, read the way a caller reads one, or nothing where there is none.
local function rowed (of: Sync, id: number): any
    local at = of.partOf[id]
    if at == nil then return nil end

    local part = of.parts[at]
    if part == nil then return nil end

    return part.store.rows[id]
end

-- Public --------------------------------------------------------------

Sync.NONE = table.freeze (CLEARED)

-- One set, holding nothing.
function Sync.new (def: Compile.Set): Sync
    local layout = Sections.of (def)
    local lane = Newest.of (layout)

    return {
        def = def,
        layout = layout,
        plan = Plan.of (layout),
        lane = lane,

        --[[
            Three answers that hold for the life of a set, kept where a write reads them rather
            than reached for through the definition every time one lands.
        ]]
        place = def.fieldIndex,
        climbs = def.climbs,
        streams = lane.streams,
        seen = Audience.new (),
        owed = Catchup.new (),
        heard = Apply.heard (),
        added = Listeners.list (Log.contained :: Listeners.Run<number, any>),
        changed = Listeners.list (Log.contained :: Listeners.Run<number, any, any>),
        removed = Listeners.list (Log.contained :: Listeners.Run<number, Types.Cause>),
        parts = {},
        order = {},
        partOf = {},
        row = table.create (def.fieldCount),
        one = table.create (1) :: { Player },
        at = 1,
    }
end

-- A record under an id that nothing else holds.
function Sync.add (of: Sync, id: number, record: any)
    identified (of, id)
    if of.partOf[id] ~= nil then refuse (of, "already holds", id) end

    local field = of.def.keyField
    local part = partition (of, if field == nil then nil else record[field])
    local slot = Store.bind (part.store, id)

    written (of, part.store, slot, record)
    marked (part, id, "add")
    of.partOf[id] = under (part.key)
end

-- Whether two values a field may hold are the same value.
local function alike (was: any, now: any): boolean
    if was == now then return true end
    if type (was) ~= "table" or type (now) ~= "table" then return false end
    if getmetatable (was :: any) ~= nil or getmetatable (now :: any) ~= nil then return false end

    for name, held in was do
        if not alike (held, (now :: any)[name]) then return false end
    end

    for name in now do
        if (was :: any)[name] == nil then return false end
    end

    return true
end

-- Some fields of a record that is already held.
function Sync.update (of: Sync, id: number, fields: any)
    local at = of.partOf[id]
    if at == nil then refuse (of, "does not hold", id) end

    local part = of.parts[at]
    local def = of.def
    local place = of.place
    local store = part.store
    local slot = store.slotOf[id]

    local dirt = part.dirt
    local mask = dirt.masks[id] or NOTHING

    local climbs = of.climbs
    local streams = of.streams

    local moved = false
    for name, value in fields do
        local field = place[name]
        if field == nil then
            Log.error (`{def.name} has no field named {name}`, { definition = def.name })
        end

        -- The one value that means a field has none, which is a table nothing else can be.
        if value == Sync.NONE and not def.optionalFields[field] then
            Log.error (`{def.name}.{name} is not optional and cannot be cleared`, {
                definition = def.name,
            })
        end

        local was = store.columns[field][slot]

        -- A field that may only climb, held to it at the call that would have lowered it.
        if
            climbs
            and def.climbingFields[field]
            and was ~= nil
            and value ~= Sync.NONE
            and value < was
        then
            Log.error (
                `{def.name}.{name} only climbs, and {value} is under {was}`,
                { definition = def.name }
            )
        end

        --[[
            A write of what the field already holds is no write at all. Nothing is dirtied and
            nothing is sent, which is what makes a settled stream cost nothing: a place writing
            every record every frame from a source that stopped moving is the ordinary idle set.
        ]]
        local now = if value == Sync.NONE then nil else value
        if alike (was, now) then continue end

        Store.write (store, slot, field, now)

        --[[
            A newest field is written and not marked. The lane that carries one compares what the
            column holds against what it last sent, so a mark here would be a second answer to a
            question the store already answers, and it would put an absolute value in a reliable
            delta, which is the one place it never goes.
        ]]
        if not streams or of.lane.place[field] == nil then
            mask = Coalesce.touched (mask, field)
            moved = true
        end
    end

    -- A call that moved nothing but newest fields owes the reliable lane nothing at all.
    if not moved then return end

    dirt.masks[id] = mask
    marked (part, id, "update")

    if Coalesce.migrates (mask, def.keyIndex) then migrated (of, part, id, slot) end
end

-- A record taken away, which is a slot the wire still has to be told about.
function Sync.remove (of: Sync, id: number)
    local at = of.partOf[id]
    if at == nil then refuse (of, "does not hold", id) end

    local part = of.parts[at]
    local slot = Store.unbind (part.store, id) :: number

    released (part, id, slot)
    of.partOf[id] = nil
end

-- Every record of every partition, gone.
function Sync.clear (of: Sync)
    for _, at in of.order do
        local part = of.parts[at]
        local dirt = part.dirt

        Store.clear (part.store)
        Newest.sweep (part.streams)
        Catchup.cleared (of.owed, at)

        table.clear (dirt.ops)
        table.clear (dirt.masks)
        table.clear (dirt.freed)
        dirt.cleared = true
    end

    table.clear (of.partOf)
end

-- Who a key's records are for, replacing whoever it was for.
function Sync.audience (of: Sync, key: any, to: Types.Recipient)
    partition (of, key)
    Audience.assign (of.seen, under (key), to)
end

-- The live record under an id, or nothing where this set does not hold one.
function Sync.get (of: Sync, id: number): any?
    local row = rowed (of, id)
    if __DEV__ and row ~= nil and not table.isfrozen (row) then table.freeze (row) end

    return row
end

-- How many records the set holds, which is every partition's count and not one of them.
function Sync.size (of: Sync): number
    local held = 0
    for _, at in of.order do
        held += of.parts[at].store.count
    end
    return held
end

-- Every record the set holds, whichever partition it is in, once each.
function Sync.walk (of: Sync): () -> (number?, any)
    local at = 1
    local id: number? = nil

    return function (): (number?, any)
        while true do
            local key = of.order[at]
            if key == nil then return nil end

            local found, row = next (of.parts[key].store.rows, id)
            if found ~= nil then
                id = found
                return found, row
            end

            at += 1
            id = nil
        end
    end
end

--[[
    A client that has just become ready, owed every record it can already see.

    Apart from the audience diff, and for the reason a diff is kept apart at all: a diff answers
    what changed, and a join changed nothing about who sees what.
]]
function Sync.joined (of: Sync, who: Player, ready: Recipients.Ready)
    local one = of.one
    one[1] = who

    for _, at in of.order do
        local part = of.parts[at]
        if part.store.count == 0 then continue end

        local to = of.seen.of[at]
        if to ~= nil and not Recipients.holds (to, who) then continue end

        Catchup.gained (of.owed, at, one, part.store)
    end
end

-- A link that has closed, which is every backlog its client was carrying and nothing else.
function Sync.left (of: Sync, who: Player) Catchup.dropped (of.owed, who) end

-- Whether anything at all is catching up, which is what the shared plan holds a reserve for.
function Sync.owing (of: Sync): boolean return of.owed.any > 0 end

--[[
    Whether a partition is open to everyone, read rather than worked out, since `resolved` settled
    it before the flush began.
]]
local function sees (of: Sync, at: any): boolean return Audience.everyone (of.seen, under (at)) end

-- One flush of one set: every partition twice, in the order the rotation reached them.
function Sync.shared (
    of: Sync,
    link: Link.Link,
    budget: Plan.Budget,
    purse: { [Player]: number }?,
    ready: Recipients.Ready,
    now: number
)
    local order = of.order
    local reach = #order
    if reach == 0 then return end

    for step = 0, reach - 1 do
        local key = order[(of.at + step - 1) % reach + 1]
        planned (of, link, budget, purse, of.parts[key], sees (of, key), ready, Plan.dropping)
    end

    for step = 0, reach - 1 do
        local key = order[(of.at + step - 1) % reach + 1]
        local part = of.parts[key]
        local open = sees (of, key)

        planned (of, link, budget, purse, part, open, ready, Plan.making)
        streamed (of, link, part, open, now)
    end

    of.at = of.at % reach + 1
end

-- One chunk of what a client is owed of one partition, queued for that client alone.
function Sync.behind (of: Sync, link: Link.Link, who: Player, room: number): number
    if of.owed.any == 0 then return 0 end

    local held = of.owed.owed[who]
    if held == nil then return 0 end

    local spent = 0
    for _, at in of.order do
        if held[at] == nil then continue end

        local part = of.parts[at]

        -- Chunks until the backlog is empty or the room is, rather than one and done.
        while true do
            local ends =
                Catchup.next (of.owed, of.layout, part.store, who, at, link.scratch, 0, room)
            if ends == 0 then break end

            local one = of.one
            one[1] = who
            Outbox.targeted (link, one, 1, sealed (of, link, ends, Blocks.ESTABLISH))

            room -= ends
            spent += ends
        end
    end

    return spent
end

-- One reliable section off the wire, into the partition it is about.
function Sync.taken (of: Sync, b: buffer, pos: number, ctx: Types.ValidateContext): number
    local layout = of.layout

    local _, key = Sections.about (layout, b, pos, ctx)
    local part = partition (of, key)

    local kind, ends = Sections.taken (layout, b, pos, part.store.prev, ctx)

    losing (of, part, kind)
    Apply.section (part.store, layout, kind, of.heard)
    gaining (of, part, kind, under (key))

    return ends
end

-- One newest section off the wire, into the partition it is about.
function Sync.stream (of: Sync, b: buffer, pos: number, ctx: Types.ValidateContext): number
    local lane = of.lane
    local at, seq, count, ends = Newest.taken (lane, b, pos, ctx)
    local part = partition (of, lane.key)

    Newest.apply (lane, part.streams, part.store, of.heard, at, seq, count)
    return ends
end

-- A caller told when a record arrives, moves or goes.
function Sync.onAdded (of: Sync, fn: (number, any) -> ()): Types.Connection
    return Listeners.connect (of.added, fn) :: any
end

function Sync.onChanged (of: Sync, fn: (number, any, any?) -> ()): Types.Connection
    of.heard.watching = true
    return Listeners.connect (of.changed, fn) :: any
end

function Sync.onRemoved (of: Sync, fn: (number, Types.Cause) -> ()): Types.Connection
    return Listeners.connect (of.removed, fn) :: any
end

-- The frame over: what its keyframes owe paid, what it did said, and what it did forgotten.
function Sync.settle (of: Sync)
    local heard = of.heard
    Apply.settle (heard)

    local gone, added, changed = Apply.parted (heard)

    for _, id in gone do
        Listeners.fan (of.removed, id, heard.causes[id])
    end

    for _, id in added do
        Listeners.fan (of.added, id, rowed (of, id))
    end

    for _, id in changed do
        Listeners.fan (of.changed, id, rowed (of, id), heard.olds[id])
    end

    Apply.forget (heard)
end

return table.freeze (Sync)
