--!strict
--!optimize 2
-- Bridge.luau — Creates and exposes the network remote instances.

local RunService = game:GetService("RunService")

-- Constants --------------------------------------------------------------

local FOLDER     = "_lync"
local RELIABLE   = "R"
local UNRELIABLE = "U"

-- State ------------------------------------------------------------------

local _reliable:   RemoteEvent           = nil :: any
local _unreliable: UnreliableRemoteEvent = nil :: any
local _isReady     = false

-- Public -----------------------------------------------------------------

local Bridge = {}

function Bridge.setup(): ()
    if _isReady then return end
    _isReady = true

    if RunService:IsServer() then
        local folder = Instance.new("Folder")
        folder.Name  = FOLDER

        local reliable    = Instance.new("RemoteEvent")
        reliable.Name     = RELIABLE
        reliable.Parent   = folder

        local unreliable    = Instance.new("UnreliableRemoteEvent")
        unreliable.Name     = UNRELIABLE
        unreliable.Parent   = folder

        folder.Parent = script.Parent.Parent

        _reliable   = reliable
        _unreliable = unreliable
    else
        local root   = script.Parent.Parent
        local folder = root:WaitForChild(FOLDER, 10)
        if not folder then error("[Lync] Network folder not found") end

        _reliable   = folder:WaitForChild(RELIABLE, 10) :: RemoteEvent
        _unreliable = folder:WaitForChild(UNRELIABLE, 10) :: UnreliableRemoteEvent
        if not _reliable or not _unreliable then error("[Lync] Network remotes not found") end
    end
end

function Bridge.reliable(): RemoteEvent
    if not _isReady then error("[Lync] Bridge.setup has not been called") end
    return _reliable
end

function Bridge.unreliable(): UnreliableRemoteEvent
    if not _isReady then error("[Lync] Bridge.setup has not been called") end
    return _unreliable
end

return table.freeze(Bridge)
