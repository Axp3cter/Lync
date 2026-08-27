--!strict
--!optimize 2
-- What a namespace has moved, counted where it happens and read as one frozen number set.

local Types = require ("@src/Types")

local Tally = {}

-- Types ---------------------------------------------------------------

export type Row = {
    sent: number,
    sentBytes: number,
    received: number,
    receivedBytes: number,
    drops: number,
}

-- Everything counted, which is the four about the namespace and one line a definition.
export type Tally = {
    flushes: number,
    sentBytes: number,
    receivedBytes: number,
    drops: number,
    definitions: { [string]: Row },
}

-- Private -------------------------------------------------------------

local function zeroed (): Row
    return { sent = 0, sentBytes = 0, received = 0, receivedBytes = 0, drops = 0 }
end

-- The fallback line, for a count about a definition the namespace never compiled.
local function line (of: Tally, name: string): Row
    local held = of.definitions[name]
    if held ~= nil then return held end

    held = zeroed ()
    of.definitions[name] = held
    return held
end

-- Public --------------------------------------------------------------

function Tally.new (names: { string }): Tally
    local definitions: { [string]: Row } = {}
    for _, name in names do
        definitions[name] = zeroed ()
    end

    return {
        flushes = 0,
        sentBytes = 0,
        receivedBytes = 0,
        drops = 0,
        definitions = definitions,
    }
end

--[[
    The row a definition's numbers are kept in. Handed out so a caller sending the same definition
    many times over can hold it rather than name it again, which is the only reason it is public.
]]
function Tally.row (of: Tally, name: string): Row return line (of, name) end

-- One send against a row already in hand, which is where the counting itself is done.
function Tally.counted (held: Row, bytes: number)
    held.sent += 1
    held.sentBytes += bytes
end

-- Counted where a block is composed, so one bound for two clients still counts once.
function Tally.sent (of: Tally, name: string, bytes: number)
    local held = line (of, name)
    Tally.counted (held, bytes)
end

--[[
    One more call against a definition, without bytes to go with it, which `carried` is the other
    half of: a run is counted where it is fired and priced where it is sealed.
]]
function Tally.fired (held: Row)
    held.sent += 1
end

-- More bytes against a definition, without a call to go with them.
function Tally.carried (of: Tally, name: string, bytes: number)
    line (of, name).sentBytes += bytes
end

-- More arrivals against a definition, without bytes to go with them: a run is one block of many.
function Tally.arrived (of: Tally, name: string, times: number)
    line (of, name).received += times
end

-- Counted off the frame, whatever became of what was inside it.
function Tally.received (of: Tally, name: string, bytes: number)
    local held = line (of, name)
    held.received += 1
    held.receivedBytes += bytes
end

-- One drop, against the definition it was about where there is one.
function Tally.dropped (of: Tally, name: string?)
    of.drops += 1
    if name == nil then return end

    line (of, name).drops += 1
end

-- The engine's own figure, above the blocks inside it, since framing rides outside them.
function Tally.moved (of: Tally, bytes: number)
    of.sentBytes += bytes
end

-- The same figure coming the other way.
function Tally.took (of: Tally, bytes: number)
    of.receivedBytes += bytes
end

function Tally.flushed (of: Tally)
    of.flushes += 1
end

--[[
    Copied and frozen, since the surface says two readings subtract into an exact rate and a caller
    who kept one is owed the numbers they took.
]]
function Tally.reading (of: Tally): Types.Stats
    local definitions: { [string]: Types.DefinitionStats } = {}

    for name, held in of.definitions do
        definitions[name] = table.freeze ({
            sent = held.sent,
            sentBytes = held.sentBytes,
            received = held.received,
            receivedBytes = held.receivedBytes,
            drops = held.drops,
        })
    end

    return table.freeze ({
        flushes = of.flushes,
        sentBytes = of.sentBytes,
        receivedBytes = of.receivedBytes,
        drops = of.drops,
        definitions = table.freeze (definitions),
    })
end

return table.freeze (Tally)
