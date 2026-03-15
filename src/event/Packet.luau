--!strict
--!optimize 2
-- Packet.luau — Packet definition and send/listen API.

local RunService = game:GetService("RunService")

local Client   = require(script.Parent.Parent.transport.Client)
local Registry = require(script.Parent.Parent.core.Registry)
local Server   = require(script.Parent.Parent.transport.Server)
local Signal   = require(script.Parent.Parent.event.Signal)
local Types    = require(script.Parent.Parent.Types)

type Connection      = Types.Connection
type PacketConfig<T> = Types.PacketConfig<T>

-- Constants --------------------------------------------------------------

local IS_SERVER = RunService:IsServer()

-- Private ----------------------------------------------------------------

-- Shared methods (both contexts)
local SharedImpl = {}

function SharedImpl.listen(self: any, callback: (...any) -> ()): Connection
    return self._signal:connect(callback)
end

function SharedImpl.once(self: any, callback: (...any) -> ()): Connection
    return self._signal:once(callback)
end

function SharedImpl.wait(self: any): ...any
    return self._signal:wait()
end

function SharedImpl.disconnectAll(self: any): ()
    self._signal:disconnectAll()
end

-- Server-only metatable — no send(), has sendTo/sendToAll/etc.
local ServerImpl = setmetatable({}, { __index = SharedImpl })
ServerImpl.__index = ServerImpl

function ServerImpl.sendTo(self: any, data: any, player: Player): ()
    Server.writeTo(player, self._id, self._name, self._codec, data, self._isUnreliable)
end

function ServerImpl.sendToAll(self: any, data: any): ()
    Server.writeToAll(self._id, self._name, self._codec, data, self._isUnreliable)
end

function ServerImpl.sendToList(self: any, data: any, players: { Player }): ()
    Server.writeToList(players, self._id, self._name, self._codec, data, self._isUnreliable)
end

function ServerImpl.sendToAllExcept(self: any, data: any, except: Player): ()
    Server.writeToAllExcept(except, self._id, self._name, self._codec, data, self._isUnreliable)
end

function ServerImpl.sendToGroup(self: any, data: any, groupName: string): ()
    Server.writeToGroup(groupName, self._id, self._name, self._codec, data, self._isUnreliable)
end

table.freeze(ServerImpl)

-- Client-only metatable — no sendTo/sendToAll, has send()
local ClientImpl = setmetatable({}, { __index = SharedImpl })
ClientImpl.__index = ClientImpl

function ClientImpl.send(self: any, data: any): ()
    Client.write(self._id, self._name, self._codec, data, self._isUnreliable)
end

table.freeze(ClientImpl)

-- Public -----------------------------------------------------------------

local Packet = {}

function Packet.define(name: string, config: PacketConfig<any>): any
    if #name == 0 then error("[Lync] Packet name must not be empty") end
    if not config.value then error(`[Lync] Packet "{name}" requires a value codec`) end

    local isUnreliable = config.unreliable == true

    if (config.value :: any)._isDelta and isUnreliable then
        error(`[Lync] Packet "{name}" uses delta codec which requires reliable delivery`)
    end

    local signal = Signal.create()

    local reg = Registry.register(
        name,
        config.value,
        isUnreliable,
        signal,
        config.rateLimit,
        config.validate
    )

    return setmetatable({
        _id           = reg.id,
        _name         = reg.name,
        _codec        = reg.codec,
        _isUnreliable = isUnreliable,
        _signal       = reg.signal,
    }, if IS_SERVER then ServerImpl else ClientImpl)
end

return table.freeze(Packet)
