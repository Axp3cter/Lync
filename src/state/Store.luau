--!strict
--!optimize 2
-- One partition's truth: a slot per record, the columns a wire reads and the rows a caller does.

local Compile = require ("@src/shape/Compile")
local Heap = require ("@src/kernel/Heap")
local Protocol = require ("@src/wire/Protocol")

local Store = {}

-- Constants -----------------------------------------------------------

-- How far a slot's generation counts before it comes round, which is what two wire bits hold.
const GENS = Protocol.NEWEST_GENS

-- What a field's marker has to be for the field to keep a last-sent index rather than a baseline.
const LATEST: Compile.Marker = "newest"

-- Types ---------------------------------------------------------------

-- A record as a caller reads one, which is the same table the callbacks are handed.
export type Record = { [string]: any }

-- One field's write, by the slot it lands on and the id whose record carries it.
export type Writer = (slot: number, id: number, value: any) -> ()

--[[
    The same write for a whole section at once. A keyframe states every slot it names for every
    field it carries, so the crossing into the store is paid once a field there rather than once a
    slot, which is the only thing between this and the one above.
]]
export type Spread = (slots: { number }, ids: { number }, values: { any }, count: number) -> ()

--[[
    One partition, held twice. `columns` is the wire's truth, one field across every slot, which a
    section writes as one lookup and then array reads. `rows` is the caller's, one record under its
    id at one lookup. One write fills both, which is why they cannot come apart. A slot is the
    lowest free one, and what that costs is the generation a receiver tells a rebind by.
]]
export type Store = {
    read def: Compile.Set,
    read fields: number,

    -- The record every row starts as, which is one answer the definition gives for the whole run.
    read template: Record,
    read columns: { { [number]: any } },
    read rows: { [number]: Record },
    read ids: { [number]: number },
    read slotOf: { [number]: number },
    read prev: { { [number]: number }? },
    read sent: { { [number]: any }? },
    read gens: { [number]: number }?,

    --[[
        One writer a field, holding the column and the name that field is known by. Both are
        settled when the partition is made, so a caller writing a whole column of slots reaches
        them once rather than working them out again for every slot it puts down.
    ]]
    read writers: { Writer },
    read spreads: { Spread },
    read free: Heap.Heap,
    high: number,
    count: number,
}

-- Private -------------------------------------------------------------

-- A slot nobody holds, and whether it has been held before.
local function taken (of: Store): number
    local gens = of.gens
    local _, held = Heap.pop (of.free)

    if held ~= nil then
        local slot = held :: number
        if gens ~= nil then gens[slot] = (gens[slot] + 1) % GENS end
        return slot
    end

    local slot = of.high + 1
    of.high = slot
    if gens ~= nil then gens[slot] = 0 end
    return slot
end

-- Public --------------------------------------------------------------

-- A partition, empty.
function Store.new (of: Compile.Set): Store
    local fields = of.fieldCount
    local columns = table.create (fields) :: { { [number]: any } }
    local prev = table.create (fields) :: { { [number]: number }? }
    local sent = table.create (fields) :: { { [number]: any }? }

    for index = 1, fields do
        local built = of.fieldBuilt[index]
        local newest = built.cell.marker == LATEST

        columns[index] = {}
        prev[index] = if built.grid ~= nil and not newest then {} else nil
        sent[index] = if newest then {} else nil
    end

    local store: Store = {
        def = of,
        fields = fields,
        template = of.template,
        columns = columns,
        rows = {},
        ids = {},
        slotOf = {},
        prev = prev,
        sent = sent,
        gens = if #of.newestFields == 0 then nil else {},
        free = Heap.new (),
        high = 0,
        count = 0,
        writers = table.create (fields) :: { Writer },
        spreads = table.create (fields) :: { Spread },
    }

    local rows = store.rows
    local names = of.fieldNames

    for index = 1, fields do
        local column = columns[index]
        local name = names[index]

        store.writers[index] = function (slot: number, id: number, value: any)
            column[slot] = value

            local row = rows[id]

            --[[
                A row a caller has been handed is frozen in a development build, so this writes a
                copy rather than raising on it. What the caller holds stays what they were told it
                was: the record as it read at the moment they took it, and borrowed rather than
                live.
            ]]
            if __DEV__ and table.isfrozen (row) then
                row = table.clone (row)
                rows[id] = row
            end

            row[name] = value
        end

        store.spreads[index] = function (
            slots: { number },
            ids: { number },
            values: { any },
            count: number
        )
            for at = 1, count do
                local id = ids[at]
                local value = values[at]

                column[slots[at]] = value

                local row = rows[id]
                if __DEV__ and table.isfrozen (row) then
                    row = table.clone (row)
                    rows[id] = row
                end

                row[name] = value
            end
        end
    end

    return store
end

-- A record under an id, at the slot it will keep until it is removed.
function Store.bind (of: Store, id: number): number
    local slot = taken (of)

    of.ids[slot] = id
    of.slotOf[id] = slot
    of.rows[id] = table.clone (of.template)
    of.count += 1

    return slot
end

-- A record at the slot the other machine chose for it.
function Store.hold (of: Store, id: number, slot: number)
    local ids = of.ids
    if ids[slot] == nil then
        of.count += 1
    end

    ids[slot] = id
    of.slotOf[id] = slot

    --[[
        A row this receiver already has is written over rather than made again. A keyframe states
        every field of every record it names, so by the time the walk that called this is done
        there is nothing of the older reading left, and a fresh table would have been filled a
        field at a time with the very same values.
    ]]
    local rows = of.rows
    if rows[id] == nil then rows[id] = table.clone (of.template) end

    if slot > of.high then of.high = slot end
end

-- A record gone, and the slot it held.
function Store.unbind (of: Store, id: number): number?
    local slotOf = of.slotOf

    local slot = slotOf[id]
    if slot == nil then return nil end

    slotOf[id] = nil
    of.ids[slot] = nil
    of.rows[id] = nil
    of.count -= 1

    return slot
end

-- A slot back where the allocator finds it, which only the machine that hands them out does.
function Store.spare (of: Store, slot: number) Heap.push (of.free, slot, slot) end

-- A partition emptied, and every slot it handed out back at the beginning.
function Store.clear (of: Store)
    for index = 1, of.fields do
        table.clear (of.columns[index])

        local baseline = of.prev[index]
        if baseline ~= nil then table.clear (baseline) end

        local last = of.sent[index]
        if last ~= nil then table.clear (last) end
    end

    local gens = of.gens
    if gens ~= nil then table.clear (gens) end

    table.clear (of.rows)
    table.clear (of.ids)
    table.clear (of.slotOf)

    of.free.count = 0
    of.high = 0
    of.count = 0
end

return table.freeze (Store)
