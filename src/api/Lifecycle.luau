--!strict
--!optimize 2
-- The place's lifecycle: the one start, the flushes that send, and the close that lets go.

local Define = require ("@src/api/Define")
local Log = require ("@src/kernel/Log")
local Session = require ("@src/runtime/Session")
local Transport = require ("@src/channel/Transport")
local Types = require ("@src/Types")

local Lifecycle = {}

-- State ---------------------------------------------------------------

--[[
    Every namespace that has been opened, under the name it was declared with.

    Module state for the reason the namespace table is: a place starts once, whatever number of
    scripts declared into it, and every call here is about all of them or about one by name.
]]
local sessions: { [string]: Session.Session } = {}
local started = false

-- Private -------------------------------------------------------------

-- Who is here, as the three things a namespace asks and no more.
local function rostered (): Session.Roster
    local players = game:GetService ("Players")

    return {
        all = function (): { Player } return players:GetPlayers () end,
        onAdded = function (_, take: (Player) -> ()): () -> ()
            local held = players.PlayerAdded:Connect (take)
            return function () held:Disconnect () end
        end,
        -- Wrapped, unlike the one above it, because this event hands over a reason as well.
        onRemoving = function (_, take: (Player) -> ()): () -> ()
            local held = players.PlayerRemoving:Connect (function (who: Player) take (who) end)
            return function () held:Disconnect () end
        end,
    }
end

-- The namespace a name reaches, refused where it reaches none.
local function opened (name: string, said: string): Session.Session
    local session = sessions[name]
    if session == nil then
        Log.error (`{said} named {name}, which is no namespace this place defined`, {
            definition = name,
        })
    end

    return session :: Session.Session
end

-- Nothing here is about a definition, so a refusal about the place itself names none.
local function running (said: string)
    if started then return end

    Log.error (`{said} before start, and nothing is open until a place starts`)
end

-- Public --------------------------------------------------------------

-- Every namespace declared, compiled, bound to its handles, and opened.
function Lifecycle.start ()
    if started then Log.error ("start has already run, and a place starts once") end
    started = true
    Define.seal ()

    local side: Transport.Side = if game:GetService ("RunService"):IsServer ()
        then "server"
        else "client"
    local roster = rostered ()

    for _, name in Define.order do
        local space = Define.spaces[name]
        local transport = Transport.new (name, side)
        local session = Session.new (name, space.defs, transport, roster, side)

        sessions[name] = session
        session:start ()
    end
end

-- Everything buffered since the last flush, out, for every namespace or for one by name.
function Lifecycle.flush (first: (string | number)?, second: number?)
    running ("flush")

    if type (first) == "string" then
        opened (first, "flush"):flush (second)
        return
    end

    for _, name in Define.order do
        sessions[name]:flush (first)
    end
end

--[[
    Every namespace closed, in the order they were declared. A second call is not a fault: what
    close promises is that the remotes are let go and nothing is left waiting, and both are true
    the second time.
]]
function Lifecycle.close ()
    running ("close")

    for _, name in Define.order do
        sessions[name]:close ()
    end
end

-- One namespace's counters, as the frozen reading two of which subtract into a rate.
function Lifecycle.stats (name: string): Types.Stats
    running ("stats")
    return opened (name, "stats"):stats ()
end

return table.freeze (Lifecycle)
