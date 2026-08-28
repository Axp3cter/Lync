--!strict
--!optimize 2
-- Where a decoded definition goes: the listeners on one, its lone responder, and neither's mistake.

local Listeners = require ("@src/kernel/Listeners")
local Log = require ("@src/kernel/Log")
local Types = require ("@src/Types")

local Dispatch = {}

-- Types ---------------------------------------------------------------

--[[
    A query's one answer. What it is handed is its side's business and not this module's: a server
    responder reads a value and a player, a client responder reads a value, and a dispatch that knew
    which would be a second home for a rule the surface already states twice.
]]
export type Responder = (...any) -> any

--[[
    Everything a machine has attached, keyed by the id the wire names. Held by whoever owns the
    namespace rather than here, because two namespaces in one place are two of these and a module
    keeping them itself would be state that depends on which of them loaded first.
]]
export type Wiring = {
    heard: { [number]: Listeners.List<...any> },
    answering: { [number]: Responder },
}

-- Private -------------------------------------------------------------

local function unheard (name: string)
    local said = `nothing on this machine listens for {name}`
    local facts: Log.Facts = { definition = name }

    --[[
        Not two reports but two builds. The raise never returns, so a place being worked on stops
        on the mistake, and the line under it is what a shipped one does with the same fact.
    ]]
    if __DEV__ then Log.error (said, facts) end
    Log.warn (said, facts)
end

-- Public --------------------------------------------------------------

function Dispatch.wiring (): Wiring return { heard = {}, answering = {} } end

-- One more listener on a definition, at the end of the order, and the connection that ends it.
function Dispatch.listen (of: Wiring, id: number, fn: (...any) -> ()): Types.Connection
    local heard = of.heard[id]
    if heard == nil then
        heard = Listeners.list (Log.contained :: Listeners.Run<...any>, Log.contains)
        of.heard[id] = heard
    end

    return Listeners.connect (heard :: Listeners.List<...any>, fn)
end

--[[
    The one responder a query gets, and a second is refused at once: by reply time both exist, and
    whichever was picked would be right half the time and silent about the rest.
]]
function Dispatch.respond (of: Wiring, id: number, name: string, fn: Responder)
    if of.answering[id] ~= nil then
        Log.error (`{name} already has a responder, and a query has one`, { definition = name })
    end

    of.answering[id] = fn
end

-- A decoded packet, to everything attached, in the order it was attached.
function Dispatch.packet (of: Wiring, id: number, name: string, ...: any)
    local heard = of.heard[id]
    if heard == nil or heard.live == 0 then
        unheard (name)
        return
    end

    Listeners.fan (heard, ...)
end

--[[
    Every payload one block carried, handed over together. A listener takes them one at a time as
    it always did, and what the block shares is the thread they arrive on.
]]
function Dispatch.packets (
    of: Wiring,
    id: number,
    name: string,
    count: number,
    values: { any },
    ...: any
)
    local heard = of.heard[id]
    if heard == nil or heard.live == 0 then
        unheard (name)
        return
    end

    Listeners.fanned (heard, count, values, ...)
end

-- A decoded request, run, and whether there is anything to send back.
function Dispatch.request (of: Wiring, id: number, ...: any): (boolean, any)
    local fn = of.answering[id]
    if fn == nil then return false, nil end

    return Log.caught (fn, ...)
end

return table.freeze (Dispatch)
