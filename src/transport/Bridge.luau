--!strict
--!optimize 2
-- RemoteEvent / UnreliableRemoteEvent thin wrapper.

local RunService = game:GetService("RunService")

-- Constants --------------------------------------------------------------

local RELIABLE_NAME = "LyncReliable"
local UNRELIABLE_NAME = "LyncUnreliable"

-- State ------------------------------------------------------------------

local _reliable: RemoteEvent? = nil
local _unreliable: UnreliableRemoteEvent? = nil
local _isServer = RunService:IsServer()

-- Private ----------------------------------------------------------------

local function ensureReliable(): RemoteEvent
    local re = _reliable
    if not re then
        error("[Lync] Bridge.reliable: not set up; call Lync.start() first")
    end
    return re
end

local function ensureUnreliable(): UnreliableRemoteEvent
    local ure = _unreliable
    if not ure then
        error("[Lync] Bridge.unreliable: not set up; call Lync.start() first")
    end
    return ure
end

-- Public -----------------------------------------------------------------

local Bridge = {}

function Bridge.setup(container: Instance): ()
    if _isServer then
        local re = Instance.new("RemoteEvent")
        re.Name = RELIABLE_NAME
        re.Parent = container

        local ure = Instance.new("UnreliableRemoteEvent")
        ure.Name = UNRELIABLE_NAME
        ure.Parent = container

        _reliable, _unreliable = re, ure
        return
    end
    _reliable = container:WaitForChild(RELIABLE_NAME) :: RemoteEvent
    _unreliable = container:WaitForChild(UNRELIABLE_NAME) :: UnreliableRemoteEvent
end

Bridge.reliable = ensureReliable
Bridge.unreliable = ensureUnreliable

function Bridge.fireServer(data: buffer, refs: { Instance }): ()
    local re = ensureReliable()
    if #refs > 0 then
        re:FireServer(data, refs)
    else
        re:FireServer(data)
    end
end

function Bridge.fireClient(player: Player, data: buffer, refs: { Instance }): ()
    local re = ensureReliable()
    if #refs > 0 then
        re:FireClient(player, data, refs)
    else
        re:FireClient(player, data)
    end
end

function Bridge.fireServerUnreliable(data: buffer, refs: { Instance }): ()
    local ure = ensureUnreliable()
    if #refs > 0 then
        ure:FireServer(data, refs)
    else
        ure:FireServer(data)
    end
end

function Bridge.fireClientUnreliable(player: Player, data: buffer, refs: { Instance }): ()
    local ure = ensureUnreliable()
    if #refs > 0 then
        ure:FireClient(player, data, refs)
    else
        ure:FireClient(player, data)
    end
end

return table.freeze(Bridge)
