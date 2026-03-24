--!strict
--!optimize 2
-- Remote instance creation and access.

local RunService = game:GetService("RunService")

-- Constants -----------------------------------------------------------

local RELIABLE_NAME = "LyncReliable"
local UNRELIABLE_NAME = "LyncUnreliable"

-- State ---------------------------------------------------------------

local _reliable: RemoteEvent? = nil
local _unreliable: UnreliableRemoteEvent? = nil
local _isServer = RunService:IsServer()

-- Public --------------------------------------------------------------

local Bridge = {}

function Bridge.setup(container: Instance): ()
    if _isServer then
        local re = Instance.new("RemoteEvent")
        re.Name = RELIABLE_NAME
        re.Parent = container

        local ure = Instance.new("UnreliableRemoteEvent")
        ure.Name = UNRELIABLE_NAME
        ure.Parent = container

        _reliable = re
        _unreliable = ure
    else
        _reliable = container:WaitForChild(RELIABLE_NAME) :: RemoteEvent
        _unreliable = container:WaitForChild(UNRELIABLE_NAME) :: UnreliableRemoteEvent
    end
end

function Bridge.reliable(): RemoteEvent
    return _reliable :: RemoteEvent
end

function Bridge.unreliable(): UnreliableRemoteEvent
    return _unreliable :: UnreliableRemoteEvent
end

function Bridge.isServer(): boolean
    return _isServer
end

function Bridge.fireServer(data: buffer, refs: { Instance }): ()
    local re = _reliable :: RemoteEvent
    if #refs > 0 then
        re:FireServer(data, refs)
    else
        re:FireServer(data)
    end
end

function Bridge.fireClient(player: Player, data: buffer, refs: { Instance }): ()
    local re = _reliable :: RemoteEvent
    if #refs > 0 then
        re:FireClient(player, data, refs)
    else
        re:FireClient(player, data)
    end
end

function Bridge.fireServerUnreliable(data: buffer, refs: { Instance }): ()
    local ure = _unreliable :: UnreliableRemoteEvent
    if #refs > 0 then
        ure:FireServer(data, refs)
    else
        ure:FireServer(data)
    end
end

function Bridge.fireClientUnreliable(player: Player, data: buffer, refs: { Instance }): ()
    local ure = _unreliable :: UnreliableRemoteEvent
    if #refs > 0 then
        ure:FireClient(player, data, refs)
    else
        ure:FireClient(player, data)
    end
end

return table.freeze(Bridge)
