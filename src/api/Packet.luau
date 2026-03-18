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

-- Server-only methods
local function serverSend(self: any, data: any, target: any?): ()
    if target == nil then
        error("[Lync] Server packet:send requires a target")
    end

    local reg = self._reg
    local isUnreliable = self._isUnreliable

    -- Single player
    if typeof(target) == "Instance" then
        if self._isDelta then
            local current = self._deltaMode
            if current == 0 then
                self._deltaMode = DELTA_TARGETED
            elseif current ~= DELTA_TARGETED then
                error(`[Lync] Delta packet cannot mix targeted and broadcast: "{reg.name}"`)
            end
        end
        Server.writeTo(target :: Player, reg, data, isUnreliable)
        return
    end

    -- Must be a table from here
    local tag = target._tag

    if self._isDelta then
        local current = self._deltaMode
        if tag == "all" or tag == "except" or tag == "group" then
            if current == 0 then
                self._deltaMode = DELTA_BROADCAST
            elseif current ~= DELTA_BROADCAST then
                error(`[Lync] Delta packet cannot mix targeted and broadcast: "{reg.name}"`)
            end
        else
            if current == 0 then
                self._deltaMode = DELTA_TARGETED
            elseif current ~= DELTA_TARGETED then
                error(`[Lync] Delta packet cannot mix targeted and broadcast: "{reg.name}"`)
            end
        end
    end

    -- Lync.all sentinel
    if tag == "all" then
        Server.writeToAll(reg, data, isUnreliable)
        return
    end

    -- Lync.except(player, ...) descriptor
    if tag == "except" then
        Server.writeToAllExcept(target._set, reg, data, isUnreliable)
        return
    end

    -- Group object
    if tag == "group" then
        Server.writeToSet(target:getSet(), reg, data, isUnreliable)
        return
    end

    -- Player list (array)
    Server.writeToList(target :: { Player }, reg, data, isUnreliable)
end

local function clientSend(self: any, data: any): ()
    Client.write(self._reg, data, self._isUnreliable)
end

local function listen(self: any, callback: (...any) -> ()): Connection
    return self._signal:connect(callback)
end

local function once(self: any, callback: (...any) -> ()): Connection
    return self._signal:once(callback)
end

local function wait(self: any): ...any
    return self._signal:wait()
end

local function disconnectAll(self: any): ()
    self._signal:disconnectAll()
end

-- Shared method tables for __index lookup
local serverMethods = {
    send = serverSend,
    listen = listen,
    once = once,
    wait = wait,
    disconnectAll = disconnectAll,
}

local clientMethods = {
    send = clientSend,
    listen = listen,
    once = once,
    wait = wait,
    disconnectAll = disconnectAll,
}

-- Server metatable with function-based __index for stats passthrough
local ServerImpl = {}
ServerImpl.__index = function(self: any, key: string)
    local m = serverMethods[key]
    if m then
        return m
    end
    local reg = rawget(self, "_reg")
    if reg then
        return (reg :: any)[key]
    end
    return nil
end

export type Packet = typeof(setmetatable({} :: PacketFields, ServerImpl))

table.freeze(ServerImpl)

-- Client metatable
local ClientImpl = {}
ClientImpl.__index = function(self: any, key: string)
    local m = clientMethods[key]
    if m then
        return m
    end
    local reg = rawget(self, "_reg")
    if reg then
        return (reg :: any)[key]
    end
    return nil
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

    local timestampMode = if config.timestamp then TS_LOOKUP[config.timestamp] else nil
    if config.timestamp and not timestampMode then
        error(`[Lync] Invalid timestamp mode: "{config.timestamp}" on packet "{name}"`)
    end

    -- Warn if codec tree contains unknown without validate
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
