--!strict
--!optimize 2
-- Creates and exposes the network remote instances.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

-- Constants --------------------------------------------------------------

local FOLDER     = "_lync"
local RELIABLE   = "R"
local UNRELIABLE = "U"
local TIMEOUT    = 10

-- State ------------------------------------------------------------------

local _reliable:   RemoteEvent
local _unreliable: UnreliableRemoteEvent

-- Public -----------------------------------------------------------------

local Bridge = {}

function Bridge.setup(): ()
    if RunService:IsServer() then
        local folder = Instance.new("Folder")
        folder.Name  = FOLDER

        local reliable    = Instance.new("RemoteEvent")
        reliable.Name     = RELIABLE
        reliable.Parent   = folder

        local unreliable    = Instance.new("UnreliableRemoteEvent")
        unreliable.Name     = UNRELIABLE
        unreliable.Parent   = folder

        folder.Parent = ReplicatedStorage

        _reliable   = reliable
        _unreliable = unreliable
    else
        local folder = ReplicatedStorage:WaitForChild(FOLDER, TIMEOUT)
        if not folder then error("[Lync] Network folder not found — is the server started?") end

        local reliable = folder:WaitForChild(RELIABLE, TIMEOUT)
        if not reliable then error("[Lync] Reliable remote not found") end

        local unreliable = folder:WaitForChild(UNRELIABLE, TIMEOUT)
        if not unreliable then error("[Lync] Unreliable remote not found") end

        _reliable   = reliable :: RemoteEvent
        _unreliable = unreliable :: UnreliableRemoteEvent
    end
end

-- No guards — callers (Server.start / Client.start) guarantee setup() ran.
function Bridge.reliable(): RemoteEvent
    return _reliable
end

function Bridge.unreliable(): UnreliableRemoteEvent
    return _unreliable
end

return table.freeze(Bridge)
