--!strict
--!optimize 2
-- The replicated set as plain tables: what the server holds, what each client should, and why.

local Lync = require ("@src")

local Expect = require ("@self/Expect")

local Oracle = {}

-- Constants -----------------------------------------------------------

--[[
    The sentinel a caller clears an optional field with, taken from the library so a suite cannot
    hand the model one and the engine another. It carries identity and no behaviour.
]]
const NONE = Lync.none

--[[
    The two reasons a record leaves a client's view. Each is composed on the receiving machine,
    because the wire carries neither: a removal names slots and nothing else, and a cause would
    announce across the audience boundary that a record existed at all.
]]
const REMOVED: Lync.Cause = "removed"
const CLEARED: Lync.Cause = "cleared"

-- Types ---------------------------------------------------------------

export type Record = { [string]: any }

--[[
    One callback a client should have seen. `old` rides only on a change, and it is the record as
    the client held it before the flush rather than any intermediate the flush coalesced away.
]]
export type Event = {
    read kind: "removed" | "added" | "changed",
    read id: number,
    read record: Record?,
    read old: Record?,
    read cause: Lync.Cause?,
}

-- What the model holds, as a record the suite hands to the functions below.
export type Oracle = {
    _key: string?,
    _records: { [number]: Record },
    _audience: { [any]: { string } },
    _views: { [string]: { [number]: Record } },
    _lossy: { [string]: boolean },
    _dropped: { [number]: boolean },
    _cleared: boolean,
    _viewers: { string },
    _settles: (Record) -> Record,
}

-- Private -------------------------------------------------------------

local function copied (of: Record): Record
    local out = {}
    for name, value in of do
        out[name] = value
    end
    return out
end

-- The ids a viewer should hold, which is every record whose key names them.
local function visible (of: Oracle, who: string): { [number]: boolean }
    local out = {}
    for id, record in of._records do
        if of._key == nil then
            out[id] = true
            continue
        end

        local granted = of._audience[record[of._key]]
        if granted == nil then continue end
        for _, viewer in granted do
            if viewer == who then out[id] = true end
        end
    end
    return out
end

-- Every id either side of a flush holds, so a comparison misses neither end.
local function touched (held: { [number]: Record }, sees: { [number]: boolean }): { number }
    local ids = {}
    for id in held do
        table.insert (ids, id)
    end
    for id in sees do
        if held[id] == nil then table.insert (ids, id) end
    end
    table.sort (ids)
    return ids
end

-- Public --------------------------------------------------------------

--[[
    A set, keyed or not. An unkeyed set is one partition every client holds, so `audience` on one is
    a call the surface refuses. `settles` is how a record reaches the wire, since a model holding
    the originals of a quantized field would call that a change nobody is told about.
]]
function Oracle.new (
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
        _key = key,
        _records = {},
        _audience = {},
        _views = views,
        _dropped = {},
        _cleared = false,
        _viewers = table.clone (viewers),
        _settles = if settles ~= nil then settles else copied,
        _lossy = if lossy ~= nil then lossy else {},
    } :: Oracle
end

--[[
    The server's own view, which every mutation reaches at once. Nothing here waits for a flush: a
    flush decides what the wire carries, and the machine that owns the records has always held them.
]]
function Oracle.add (of: Oracle, id: number, record: Record)
    assert (of._records[id] == nil, `add of a live id {id}`)
    of._records[id] = of._settles (copied (record))
end

function Oracle.update (of: Oracle, id: number, fields: Record)
    local held = of._records[id]
    assert (held ~= nil, `update of an absent id {id}`)

    local grown = copied (held)
    for name, value in fields do
        grown[name] = if value == NONE then nil else value
    end
    of._records[id] = of._settles (grown)
end

function Oracle.remove (of: Oracle, id: number)
    assert (of._records[id] ~= nil, `remove of an absent id {id}`)
    of._records[id] = nil
    of._dropped[id] = true
end

--[[
    The whole partition. A clear is one section rather than a removal each and a client cannot see
    past it, so every record leaving a view in a flush that cleared left under the clear whatever
    else happened to it. The walk is what makes a clear and an add back read as the two they are.
]]
function Oracle.clear (of: Oracle)
    of._cleared = true
    for id in of._records do
        of._dropped[id] = true
    end
    of._records = {}
end

--[[
    Who sees a key from now on, replacing whoever saw it before. A resolved list, since what an
    `Except` or a `Group` stands for is settled once by the library, and a second resolver here
    would be a second answer to the same question.
]]
function Oracle.audience (of: Oracle, key: any, viewers: { string })
    assert (of._key ~= nil, "audience on a set with no key")
    of._audience[key] = table.clone (viewers)
end

--[[
    A flush as one line: `-id:cause` for a removal, `+id` for a keyframe, `~id` for a change. Two of
    these side by side are how a divergence is reported.
]]
function Oracle.line (events: { Event }): string
    local out = table.create (#events)

    for _, event in events do
        if event.kind == "removed" then
            table.insert (out, `-{event.id}:{event.cause}`)
        elseif event.kind == "added" then
            table.insert (out, `+{event.id}`)
        else
            table.insert (out, `~{event.id}`)
        end
    end
    return table.concat (out, " ")
end

--[[
    A client arriving or departing. A joiner holds nothing, so its first flush hands it every record
    it can see. A leaver stops being asked and the view it held stays readable, that being the
    inventory a teardown walks.
]]
function Oracle.joins (of: Oracle, who: string)
    assert (of._views[who] == nil, `{who} has already joined`)
    of._views[who] = {}
    table.insert (of._viewers, who)
end

function Oracle.leaves (of: Oracle, who: string)
    local at = table.find (of._viewers, who)
    assert (at ~= nil, `{who} is not a viewer`)
    table.remove (of._viewers, at)
end

--[[
    What the server holds, and what a client holds as of the last flush. The live tables: a copy per
    call would cost every comparison a walk of the whole set to defend against a caller that is
    ours.
]]
function Oracle.truth (of: Oracle): { [number]: Record } return of._records end

function Oracle.view (of: Oracle, who: string): { [number]: Record }
    return assert (of._views[who], `no viewer {who}`)
end

--[[
    What each client should have been told, and what it should hold afterwards. The whole model is
    one comparison, so the net effect of a flush falls out rather than being computed and a run of
    mutations that cancel says nothing.
]]
function Oracle.flush (of: Oracle): { [string]: { Event } }
    local out = {}

    for _, who in of._viewers do
        local held = of._views[who]
        local sees = visible (of, who)
        local after = {}

        local gone: { Event } = {}
        local fresh: { Event } = {}
        local changed: { Event } = {}

        for _, id in touched (held, sees) do
            local was = held[id]
            local now = if sees[id] then of._records[id] else nil
            local dropped = of._dropped[id]
            local cause = if of._cleared and dropped then CLEARED else REMOVED

            if now == nil then
                if was ~= nil then
                    table.insert (gone, { kind = "removed" :: "removed", id = id, cause = cause })
                end
                continue
            end

            after[id] = copied (now)
            if was == nil then
                table.insert (fresh, { kind = "added" :: "added", id = id, record = after[id] })
                continue
            end

            --[[
                A record taken away and put back inside one flush, which is a departure and an
                arrival only where it came back to the same partition.
            ]]
            local key = of._key
            if dropped and (key == nil or was[key] == now[key]) then
                table.insert (gone, { kind = "removed" :: "removed", id = id, cause = cause })
                table.insert (fresh, { kind = "added" :: "added", id = id, record = after[id] })
                continue
            end

            --[[
                Whether the update wrote the value the record already held, which decides whether
                this client hears anything at all. `Expect` owns the comparison: a composite
                arrives as a fresh table every write and NaN is not equal to itself.
            ]]
            if Expect.alike (was, now) then continue end

            --[[
                The record as the reliable lane leaves it, which is every field that moved except
                the ones on the lossy lane.
            ]]
            local middle = copied (was)
            local split = false

            for name, value in now do
                if of._lossy[name] then continue end
                if Expect.alike (middle[name], value) then continue end

                middle[name] = value
            end

            for name in of._lossy do
                if Expect.alike (was[name], now[name]) then continue end
                split = not Expect.alike (middle, was)
            end

            if split then
                table.insert (
                    changed,
                    { kind = "changed" :: "changed", id = id, record = middle, old = was }
                )
                table.insert (
                    changed,
                    { kind = "changed" :: "changed", id = id, record = after[id], old = middle }
                )
                continue
            end

            table.insert (
                changed,
                { kind = "changed" :: "changed", id = id, record = after[id], old = was }
            )
        end

        table.move (fresh, 1, #fresh, #gone + 1, gone)
        table.move (changed, 1, #changed, #gone + 1, gone)

        of._views[who] = after
        out[who] = gone
    end

    of._dropped = {}
    of._cleared = false
    return out
end

return table.freeze (Oracle)
