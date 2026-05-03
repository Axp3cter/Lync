--!strict
--!optimize 2
-- RemoteEvent / UnreliableRemoteEvent wrapper.

local RunService = game:GetService("RunService")

local Log = require(script.Parent.Parent.util.Log)

-- Constants --------------------------------------------------------------

local RELIABLE_NAME = "LyncReliable"
local UNRELIABLE_NAME = "LyncUnreliable"

-- State ------------------------------------------------------------------

local _reliable: RemoteEvent? = nil
local _unreliable: UnreliableRemoteEvent? = nil
local _isServer = RunService:IsServer()

-- Private ----------------------------------------------------------------

--[[
    Captured to a local first so Log.error's `never` return narrows the
    optional. Reading the module global directly wouldn't narrow.
]]
local function ensureReliable(): RemoteEvent
    local r = _reliable
    if not r then
        Log.error("not set up; call Lync.start() first")
    end
    return r
end

local function ensureUnreliable(): UnreliableRemoteEvent
    local u = _unreliable
    if not u then
        Log.error("not set up; call Lync.start() first")
    end
    return u
end

-- Drop the trailing arg when refs is empty: Roblox serializes empty tables as several wire bytes.
local function fireToServer(re: any, data: buffer, refs: { Instance }): ()
    if #refs > 0 then
        re:FireServer(data, refs)
    else
        re:FireServer(data)
    end
end

local function fireToClient(re: any, player: Player, data: buffer, refs: { Instance }): ()
    if #refs > 0 then
        re:FireClient(player, data, refs)
    else
        re:FireClient(player, data)
    end
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
    fireToServer(ensureReliable(), data, refs)
end

function Bridge.fireClient(player: Player, data: buffer, refs: { Instance }): ()
    fireToClient(ensureReliable(), player, data, refs)
end

function Bridge.fireServerUnreliable(data: buffer, refs: { Instance }): ()
    fireToServer(ensureUnreliable(), data, refs)
end

function Bridge.fireClientUnreliable(player: Player, data: buffer, refs: { Instance }): ()
    fireToClient(ensureUnreliable(), player, data, refs)
end

-- Test injection point: harnesses substitute fake remotes.
function Bridge.attach(reliable: any, unreliable: any): ()
    _reliable = reliable
    _unreliable = unreliable
end

function Bridge.reset(): ()
    _reliable = nil
    _unreliable = nil
end

return table.freeze(Bridge)
