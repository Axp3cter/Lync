--!strict
--!optimize 2
-- The replicated set as plain tables: what the server holds, what each client should, and why.

local Set = require("@src/api/Set")
local Types = require("@src/Types")

local Expect = require("@self/Expect")

local Oracle = {}

-- The sentinel a caller clears an optional field with, taken from the library so a suite cannot
-- hand the model one and the engine another.
local NONE = Set.NONE

-- The two reasons a record leaves a client's view, both composed on the receiving machine since
-- the wire carries neither.
local REMOVED: Types.Cause = "removed"
local CLEARED: Types.Cause = "cleared"

export type Record = { [string]: any }

-- One callback a client should have seen. `old` rides only on a change, and it is the record as
-- the client held it before the flush rather than any intermediate the flush coalesced away.
export type Event = {
    read kind: "removed" | "added" | "changed",
    read id: number,
    read record: Record?,
    read old: Record?,
    read cause: Types.Cause?,
}

-- `records` holds every record as the wire leaves it and `raw` as the caller wrote it, since the
-- engine decides whether a write moved a field against the caller's values.
export type Oracle = {
    key: string?,
    records: { [number]: Record },
    raw: { [number]: Record },
    audience: { [any]: { string } },
    views: { [string]: { [number]: Record } },
    lossy: { [string]: boolean },
    dropped: { [number]: boolean },
    touched: { [number]: { [string]: boolean } },
    cleared: boolean,
    viewers: { string },
    settles: (Record) -> Record,
}

-- Private -------------------------------------------------------------

local function copied(of: Record): Record
    return table.clone(of)
end

-- Whether the engine takes two written values for the same value: the same thing, or two plain
-- tables of the same things. A buffer or a datatype that merely reads the same is a write.
local function sameWrite(was: any, now: any): boolean
    if was == now then return true end
    if type(was) ~= "table" or type(now) ~= "table" then return false end
    if getmetatable(was) ~= nil or getmetatable(now) ~= nil then return false end
    for name, held in was do
        if not sameWrite(held, now[name]) then return false end
    end
    for name in now do
        if was[name] == nil then return false end
    end
    return true
end

-- The ids a viewer should hold: every record whose key names them, or all where there is no key.
local function visible(of: Oracle, who: string): { [number]: boolean }
    local out = {}
    for id, record in of.records do
        if of.key == nil then
            out[id] = true
            continue
        end
        local granted = of.audience[record[of.key]]
        if granted ~= nil and table.find(granted, who) ~= nil then out[id] = true end
    end
    return out
end

-- Every id either side of a flush holds, so a comparison misses neither end.
local function touched(held: { [number]: Record }, sees: { [number]: boolean }): { number }
    local ids = {}
    for id in held do
        table.insert(ids, id)
    end
    for id in sees do
        if held[id] == nil then table.insert(ids, id) end
    end
    table.sort(ids)
    return ids
end

local function removed(id: number, cause: Types.Cause): Event
    return { kind = "removed", id = id, cause = cause }
end

local function added(id: number, record: Record): Event
    return { kind = "added", id = id, record = record }
end

local function changed(id: number, record: Record, old: Record): Event
    return { kind = "changed", id = id, record = record, old = old }
end

-- Whether a client holding `was` hears the reliable half of a flush as a change. Only a field the
-- engine saw move ships, whatever it moved to later, and on receipt a value is written and
-- reported only where it is a different thing from what the column held, which a table or a
-- buffer read off the wire always is.
local function heard(of: Oracle, id: number, was: Record, now: Record): boolean
    local dirty = of.touched[id]
    if dirty == nil then return false end
    for name in dirty do
        local value = now[name]
        if type(value) == "table" or type(value) == "buffer" then return true end
        if value ~= was[name] then return true end
    end
    return false
end

-- The change events one client hears for a record that moved. The reliable lane carries every
-- field that moved except the lossy ones, so a flush that moved both kinds is heard as two
-- changes, the reliable one first.
local function changes(of: Oracle, id: number, was: Record, now: Record): { Event }
    local middle = copied(was)
    for name, value in now do
        if not of.lossy[name] and not Expect.alike(middle[name], value) then
            middle[name] = value
        end
    end

    local lossyMoved = false
    for name in of.lossy do
        if not Expect.alike(was[name], now[name]) then lossyMoved = true end
    end
    if lossyMoved and not Expect.alike(middle, was) then
        return { changed(id, middle, was), changed(id, now, middle) }
    end
    return { changed(id, now, was) }
end

-- What one client should be told by a flush, and what it holds afterwards: removals first, then
-- arrivals, then changes.
local function told(of: Oracle, who: string): ({ Event }, { [number]: Record })
    local held = of.views[who]
    local sees = visible(of, who)
    local after = {}
    local gone: { Event } = {}
    local fresh: { Event } = {}
    local moved: { Event } = {}

    for _, id in touched(held, sees) do
        local was = held[id]
        local now = if sees[id] then of.records[id] else nil
        local dropped = of.dropped[id]
        local cause = if of.cleared and dropped then CLEARED else REMOVED

        if now == nil then
            if was ~= nil then table.insert(gone, removed(id, cause)) end
            continue
        end
        after[id] = copied(now)
        if was == nil then
            table.insert(fresh, added(id, after[id]))
        elseif dropped and (of.key == nil or was[of.key] == now[of.key]) then
            -- Taken away and put back inside one flush, which is a departure and an arrival only
            -- where it came back to the same partition.
            table.insert(gone, removed(id, cause))
            table.insert(fresh, added(id, after[id]))
        elseif heard(of, id, was, now) or not Expect.alike(was, now) then
            local heard = changes(of, id, was, after[id])
            table.move(heard, 1, #heard, #moved + 1, moved)
        end
    end

    table.move(fresh, 1, #fresh, #gone + 1, gone)
    table.move(moved, 1, #moved, #gone + 1, gone)
    return gone, after
end

-- Public --------------------------------------------------------------

-- A set, keyed or not. `settles` is how a record reaches the wire, since a model holding the
-- originals of a quantized field would call that a change nobody is told about.
function Oracle.new(
    key: string?,
    viewers: { string },
    settles: ((Record) -> Record)?,
    lossy: { [string]: boolean }?
): Oracle
    local views = {}
    for _, who in viewers do
        views[who] = {}
    end
    return {
        key = key,
        records = {},
        raw = {},
        audience = {},
        views = views,
        lossy = lossy or {},
        dropped = {},
        touched = {},
        cleared = false,
        viewers = table.clone(viewers),
        settles = settles or copied,
    }
end

-- The server's own view, which every mutation reaches at once.
function Oracle.add(of: Oracle, id: number, record: Record)
    assert(of.records[id] == nil, `add of a live id {id}`)
    of.raw[id] = copied(record)
    of.records[id] = of.settles(copied(record))
end

function Oracle.update(of: Oracle, id: number, fields: Record)
    local held = assert(of.records[id], `update of an absent id {id}`)
    local raw = of.raw[id]
    local grown = copied(held)
    for name, value in fields do
        local now = if value == NONE then nil else value
        if not of.lossy[name] and not sameWrite(raw[name], now) then
            local dirty = of.touched[id] or {}
            dirty[name] = true
            of.touched[id] = dirty
        end
        raw[name] = now
        grown[name] = now
    end
    of.records[id] = of.settles(grown)
end

function Oracle.remove(of: Oracle, id: number)
    assert(of.records[id] ~= nil, `remove of an absent id {id}`)
    of.records[id] = nil
    of.raw[id] = nil
    of.dropped[id] = true
end

-- The whole partition. Every record leaving a view in a flush that cleared left under the clear,
-- whatever else happened to it.
function Oracle.clear(of: Oracle)
    of.cleared = true
    for id in of.records do
        of.dropped[id] = true
    end
    of.records = {}
    of.raw = {}
end

-- Who sees a key from now on, replacing whoever saw it before, as a resolved list.
function Oracle.audience(of: Oracle, key: any, viewers: { string })
    assert(of.key ~= nil, "audience on a set with no key")
    of.audience[key] = table.clone(viewers)
end

-- A flush as one line: `-id:cause` for a removal, `+id` for a keyframe, `~id` for a change.
function Oracle.line(events: { Event }): string
    local out = table.create(#events)
    for _, event in events do
        if event.kind == "removed" then
            table.insert(out, `-{event.id}:{event.cause}`)
        elseif event.kind == "added" then
            table.insert(out, `+{event.id}`)
        else
            table.insert(out, `~{event.id}`)
        end
    end
    return table.concat(out, " ")
end

-- A joiner holds nothing, so its first flush hands it every record it can see. A leaver drops out
-- of the walk, so no later flush composes anything for it.
function Oracle.joins(of: Oracle, who: string)
    assert(of.views[who] == nil, `{who} has already joined`)
    of.views[who] = {}
    table.insert(of.viewers, who)
end

function Oracle.leaves(of: Oracle, who: string)
    local at = assert(table.find(of.viewers, who), `{who} is not a viewer`)
    table.remove(of.viewers, at)
end

-- What the server holds, and what a client holds as of the last flush, as the live tables.
function Oracle.truth(of: Oracle): { [number]: Record }
    return of.records
end

function Oracle.view(of: Oracle, who: string): { [number]: Record }
    return assert(of.views[who], `no viewer {who}`)
end

-- What each client should have been told, and what it should hold afterwards. The whole model is
-- one comparison, so a run of mutations that cancel says nothing.
function Oracle.flush(of: Oracle): { [string]: { Event } }
    local out = {}
    for _, who in of.viewers do
        local events, after = told(of, who)
        of.views[who] = after
        out[who] = events
    end
    of.dropped = {}
    of.touched = {}
    of.cleared = false
    return out
end

return table.freeze(Oracle)
