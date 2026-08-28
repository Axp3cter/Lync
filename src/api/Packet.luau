--!strict
--!optimize 2
-- The packet handle: what a caller declares before start, and what they fire and hear after it.

local Base = require ("@src/codec/Base")
local Define = require ("@src/api/Define")
local Handles = require ("@src/runtime/Handles")
local Legality = require ("@src/shape/Legality")
local Serial = require ("@src/shape/Serial")
local Types = require ("@src/Types")

local Packet = {}
Packet.__index = Packet

-- Private -------------------------------------------------------------

local function hears (self: any, fn: (...any) -> ()): Types.Connection
    local live = self.live

    -- The id is read inside, because a handle attached before it was bound has none yet.
    return Handles.later (live, function (of) return of:listen (live.id :: number, fn) end)
end

-- Public --------------------------------------------------------------

function Packet.new <T>(of: Types.Codec<T>): Types.Packet<T>
    --[[
        Level two is the caller, so a schema refused at start names the line a caller declared on
        rather than the line that found the fault.
    ]]
    local file, line = debug.info (2, "sl")
    local self = {
        kind = "packet" :: "packet",
        of = of,
        isUnreliable = false,
        isNewest = false,
        hz = nil :: number?,
        isTimestamped = false,
        at = { file = file, line = line },
        live = Handles.live (),
    }

    return (setmetatable (self, Packet) :: any) :: Types.Packet<T>
end

-- Lossy and unordered, and every fire still goes out.
function Packet.unreliable (self: any): any
    Define.declaring (self.live, "unreliable")
    self.isUnreliable = true
    return self
end

-- Lossy, latest wins, and rate capped where a rate is named.
function Packet.newest (self: any, hz: number?): any
    Define.declaring (self.live, "newest")
    self.isNewest = true
    self.hz = hz
    return self
end

-- Stamped with the instant it was fired, which is comparable across clients.
function Packet.timestamped (self: any): any
    Define.declaring (self.live, "timestamped")
    self.isTimestamped = true
    return self
end

--[[
    One fire at the server, which is the only place a client can reach.

    No recipient, because there is one. That asymmetry is the surface's own and is not composed
    here: a client naming who to send to would be naming the machine it is already talking to.
]]
function Packet.fireServer (self: any, value: any)
    local live = self.live
    Define.reach (live, "fireServer", false):fire (live.def, nil, value)
end

-- One fire at whoever the recipient names, which only a server has anybody to name.
function Packet.fireClient (self: any, to: Types.Recipient, value: any)
    local live = self.live
    Define.reach (live, "fireClient", true):fire (live.def, to, value)
end

--[[
    The number both listeners take last is the instant of the fire, and it arrives only where the
    packet was declared stamped. Every other fire hands the listener nothing in its place.
]]
function Packet.onServer (self: any, fn: (any, Player, number?) -> ()): Types.Connection
    return hears (self, fn)
end

function Packet.onClient (self: any, fn: (any, number?) -> ()): Types.Connection
    return hears (self, fn)
end

-- The schema as text, which is what a report quotes back when a decode is refused.
function Packet.describe (self: any): string
    return Serial.frame ({
        kind = "packet",
        of = { cell = Base.cell (self.of) },
        delivery = Legality.delivery (self),
        hz = self.hz,
        timestamped = self.isTimestamped,
    })
end

return table.freeze (Packet)
