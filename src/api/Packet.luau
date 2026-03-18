--!strict
--!optimize 2
-- Packet definition and send/listen API.

local RunService = game:GetService("RunService")

local Channel = require(script.Parent.Parent.internal.Channel)
local Client = require(script.Parent.Parent.transport.Client)
local Registry = require(script.Parent.Parent.internal.Registry)
local Server = require(script.Parent.Parent.transport.Server)
local Signal = require(script.Parent.Signal)
local Types = require(script.Parent.Parent.Types)

type Connection = Types.Connection
type Codec<T> = Types.Codec<T>
type InternalCodec<T> = Types.InternalCodec<T>
type PacketConfig<T> = Types.PacketConfig<T>
type Registration = Types.Registration

-- Constants -----------------------------------------------------------

local IS_SERVER = RunService:IsServer()

local DELTA_TARGETED = 1
local DELTA_BROADCAST = 2

local TS_LOOKUP = {
    frame = Channel.TS_FRAME,
    offset = Channel.TS_OFFSET,
    full = Channel.TS_FULL,
}

-- Private -------------------------------------------------------------

type PacketFields = {
    _reg: Registration,
    _isUnreliable: boolean,
    _isDelta: boolean,
    _deltaMode: number,
    _signal: Signal.Signal,
}

local function checkDeltaMode(self: any, mode: number): ()
    if not self._isDelta then
        return
    end
    local current = self._deltaMode
    if current == 0 then
        self._deltaMode = mode
    elseif current ~= mode then
        error(`[Lync] Delta packet cannot mix targeted and broadcast: "{self._reg.name}"`)
    end
end

-- Server-only metatable
local ServerImpl = {}
ServerImpl.__index = ServerImpl

export type Packet = typeof(setmetatable({} :: PacketFields, ServerImpl))

function ServerImpl.listen(self: Packet, callback: (...any) -> ()): Connection
    return self._signal:connect(callback)
end

function ServerImpl.once(self: Packet, callback: (...any) -> ()): Connection
    return self._signal:once(callback)
end

function ServerImpl.wait(self: Packet): ...any
    return self._signal:wait()
end

function ServerImpl.disconnectAll(self: Packet): ()
    self._signal:disconnectAll()
end

function ServerImpl.send(self: Packet, data: any, target: any?): ()
    if target == nil then
        error("[Lync] Server packet:send requires a target")
    end

    local reg = self._reg
    local isUnreliable = self._isUnreliable

    if typeof(target) == "Instance" then
        checkDeltaMode(self, DELTA_TARGETED)
        Server.writeTo(target :: Player, reg, data, isUnreliable)
        return
    end

    local tag = target._tag

    if tag == "all" then
        checkDeltaMode(self, DELTA_BROADCAST)
        Server.writeToAll(reg, data, isUnreliable)
        return
    end

    if tag == "except" then
        checkDeltaMode(self, DELTA_BROADCAST)
        Server.writeToAllExcept(target._set, reg, data, isUnreliable)
        return
    end

    if tag == "group" then
        checkDeltaMode(self, DELTA_BROADCAST)
        Server.writeToSet(target:getSet(), reg, data, isUnreliable)
        return
    end

    checkDeltaMode(self, DELTA_TARGETED)
    Server.writeToList(target :: { Player }, reg, data, isUnreliable)
end

-- Stats: read directly from registration
function ServerImpl.getBytesSent(self: Packet): number
    return self._reg.bytesSent
end

function ServerImpl.getBytesReceived(self: Packet): number
    return self._reg.bytesReceived
end

function ServerImpl.getFires(self: Packet): number
    return self._reg.fires
end

function ServerImpl.getRecvFires(self: Packet): number
    return self._reg.recvFires
end

function ServerImpl.getDrops(self: Packet): number
    return self._reg.drops
end

table.freeze(ServerImpl)

-- Client-only metatable
local ClientImpl = {}
ClientImpl.__index = ClientImpl

function ClientImpl.listen(self: Packet, callback: (...any) -> ()): Connection
    return self._signal:connect(callback)
end

function ClientImpl.once(self: Packet, callback: (...any) -> ()): Connection
    return self._signal:once(callback)
end

function ClientImpl.wait(self: Packet): ...any
    return self._signal:wait()
end

function ClientImpl.disconnectAll(self: Packet): ()
    self._signal:disconnectAll()
end

function ClientImpl.send(self: Packet, data: any): ()
    Client.write(self._reg, data, self._isUnreliable)
end

ClientImpl.getBytesSent = ServerImpl.getBytesSent
ClientImpl.getBytesReceived = ServerImpl.getBytesReceived
ClientImpl.getFires = ServerImpl.getFires
ClientImpl.getRecvFires = ServerImpl.getRecvFires
ClientImpl.getDrops = ServerImpl.getDrops

table.freeze(ClientImpl)

-- Public --------------------------------------------------------------

local PacketModule = {}

function PacketModule.define(name: string, config: PacketConfig<any>): Packet
    if #name == 0 then
        error("[Lync] Packet name must not be empty")
    end
    if not config.value then
        error(`[Lync] Packet requires a value codec: "{name}"`)
    end

    local isUnreliable = config.unreliable or false

    if (config.value :: InternalCodec<any>)._isDelta and isUnreliable then
        error(`[Lync] Delta codec requires reliable delivery: "{name}"`)
    end

    local timestampMode = if config.timestamp then TS_LOOKUP[config.timestamp] else nil
    if config.timestamp and not timestampMode then
        error(`[Lync] Invalid timestamp mode: "{config.timestamp}" on packet "{name}"`)
    end

    if timestampMode then
        Channel.enableTimestamps()
    end

    local hasUnknown = (config.value :: any)._hasUnknown
    if hasUnknown and not config.validate then
        warn(
            `[Lync] Packet "{name}" uses Lync.unknown: client data bypasses schema validation. Add a validate callback.`
        )
    end

    local signal = Signal.create()

    local reg = Registry.register(
        name,
        config.value,
        isUnreliable,
        signal,
        config.rateLimit,
        config.validate,
        config.maxPayloadBytes,
        timestampMode
    )

    local isDelta = (config.value :: InternalCodec<any>)._isDelta == true

    local fields: PacketFields = {
        _reg = reg,
        _isUnreliable = isUnreliable,
        _isDelta = isDelta,
        _deltaMode = 0,
        _signal = signal,
    }

    if IS_SERVER then
        return setmetatable(fields, ServerImpl)
    end
    return setmetatable(fields, ClientImpl) :: Packet
end

return table.freeze(PacketModule)
