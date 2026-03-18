--!strict
--!optimize 2
-- Packet definition and send/listen API.

local RunService = game:GetService("RunService")

local Client = require(script.Parent.Parent.transport.Client)
local Registry = require(script.Parent.Parent.internal.Registry)
local Server = require(script.Parent.Parent.transport.Server)
local Signal = require(script.Parent.Signal)
local Types = require(script.Parent.Parent.Types)

type Connection = Types.Connection
type Codec<T> = Types.Codec<T>
type InternalCodec<T> = Types.InternalCodec<T>
type PacketConfig<T> = Types.PacketConfig<T>

-- Constants -----------------------------------------------------------

local IS_SERVER = RunService:IsServer()

local serverWriteTo = Server.writeTo
local serverWriteToAll = Server.writeToAll
local serverWriteToList = Server.writeToList
local serverWriteToAllExcept = Server.writeToAllExcept
local serverWriteToSet = Server.writeToSet
local clientWrite = Client.write

local DELTA_TARGETED = 1
local DELTA_BROADCAST = 2

-- Private -------------------------------------------------------------

type PacketFields = {
    _id: number,
    _name: string,
    _codec: Codec<any>,
    _isUnreliable: boolean,
    _isDelta: boolean,
    _deltaMode: number,
    _signal: Signal.Signal,
}

-- Shared methods(both contexts)
local SharedImpl = {}

function SharedImpl.listen(self: Packet, callback: (...any) -> ()): Connection
    return self._signal:connect(callback)
end

function SharedImpl.once(self: Packet, callback: (...any) -> ()): Connection
    return self._signal:once(callback)
end

function SharedImpl.wait(self: Packet): ...any
    return self._signal:wait()
end

function SharedImpl.disconnectAll(self: Packet): ()
    self._signal:disconnectAll()
end

-- Server-only metatable. Single send() dispatches on target type.
local ServerImpl = setmetatable({}, { __index = SharedImpl })
ServerImpl.__index = ServerImpl

export type Packet = typeof(setmetatable({} :: PacketFields, ServerImpl))

local function checkDeltaMode(self: Packet, mode: number): ()
    if not self._isDelta then
        return
    end
    local current = self._deltaMode
    if current == 0 then
        self._deltaMode = mode
    elseif current ~= mode then
        error(`[Lync] Delta packet cannot mix targeted and broadcast: "{self._name}"`)
    end
end

function ServerImpl.send(self: Packet, data: any, target: any?): ()
    if target == nil then
        error("[Lync] Server packet:send requires a target")
    end

    local id = self._id
    local name = self._name
    local codec = self._codec
    local isUnreliable = self._isUnreliable

    -- Single player
    if typeof(target) == "Instance" then
        checkDeltaMode(self, DELTA_TARGETED)
        serverWriteTo(target :: Player, id, name, codec, data, isUnreliable)
        return
    end

    -- Must be a table from here
    local tag = target._tag

    -- Lync.all sentinel
    if tag == "all" then
        checkDeltaMode(self, DELTA_BROADCAST)
        serverWriteToAll(id, name, codec, data, isUnreliable)
        return
    end

    -- Lync.except(player, ...) descriptor
    if tag == "except" then
        checkDeltaMode(self, DELTA_BROADCAST)
        serverWriteToAllExcept(target._set, id, name, codec, data, isUnreliable)
        return
    end

    -- Group object
    if tag == "group" then
        checkDeltaMode(self, DELTA_BROADCAST)
        serverWriteToSet(target:getSet(), id, name, codec, data, isUnreliable)
        return
    end

    -- Player list(array)
    checkDeltaMode(self, DELTA_TARGETED)
    serverWriteToList(target :: { Player }, id, name, codec, data, isUnreliable)
end

table.freeze(ServerImpl)

-- Client-only metatable. Has send(), no target needed.
local ClientImpl = setmetatable({}, { __index = SharedImpl })
ClientImpl.__index = ClientImpl

function ClientImpl.send(self: Packet, data: any): ()
    clientWrite(self._id, self._name, self._codec, data, self._isUnreliable)
end

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

    local signal = Signal.create()

    local reg = Registry.register(
        name,
        config.value,
        isUnreliable,
        signal,
        config.rateLimit,
        config.validate,
        config.maxPayloadBytes
    )

    local isDelta = (config.value :: InternalCodec<any>)._isDelta == true

    local fields: PacketFields = {
        _id = reg.id,
        _name = reg.name,
        _codec = reg.codec,
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
