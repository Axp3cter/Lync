--!strict
--!optimize 2
-- Packet definition, send, on, once, wait, stats.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Baseline = require(script.Parent.Parent.internal.Baseline)
local Channel = require(script.Parent.Parent.internal.Channel)
local Middleware = require(script.Parent.Parent.internal.Middleware)
local Registry = require(script.Parent.Parent.internal.Registry)
local Types = require(script.Parent.Parent.Types)

-- Constants -----------------------------------------------------------

local IS_SERVER = RunService:IsServer()

-- Private -------------------------------------------------------------

local function resolveTimestampMode(ts: string?): (number, number)
    if ts == "frame" then
        Channel.enableTimestamps()
        return Channel.TS_FRAME, 2
    elseif ts == "offset" then
        Channel.enableTimestamps()
        return Channel.TS_OFFSET, 3
    elseif ts == "full" then
        Channel.enableTimestamps()
        return Channel.TS_FULL, 9
    end
    return Channel.TS_NONE, 1
end

-- Public --------------------------------------------------------------

local Packet = {}

export type PacketHandle = {
    send: (self: PacketHandle, data: any, target: any?) -> (),
    on: (self: PacketHandle, fn: (...any) -> ()) -> Types.Connection,
    once: (self: PacketHandle, fn: (...any) -> ()) -> Types.Connection,
    wait: (self: PacketHandle) -> ...any,
    name: (self: PacketHandle) -> string,
    stats: (self: PacketHandle) -> Types.PacketStats,
}

function Packet.define(
    name: string,
    codec: Types.InternalCodec<any>,
    options: Types.PacketOptions?
): PacketHandle
    local opts = options or {} :: Types.PacketOptions
    local isUnreliable = opts.unreliable or false

    if isUnreliable and (codec :: any)._isDelta then
        error(`[Lync] Lync.packet: "{name}" cannot use delta codecs with unreliable transport`)
    end

    if (codec :: any)._hasUnknown and not opts.validate then
        warn(
            `[Lync] Lync.packet: "{name}" uses unknown codec without validate — data bypasses schema validation`
        )
    end

    if (codec :: any)._isDelta then
        Baseline.markHasDelta()
    end

    local tsMode, headerSize = resolveTimestampMode(opts.timestamp)
    local needsGate = IS_SERVER

    local openFn = Channel.resolveOpenFn(tsMode, name)

    local reg = Registry.register(
        name,
        Registry.KIND_PACKET,
        codec,
        isUnreliable,
        nil,
        needsGate,
        headerSize,
        tsMode,
        openFn,
        opts.rateLimit,
        opts.validate,
        opts.maxPayloadBytes
    )

    -- Lazy-require Server/Client to avoid circular dependency
    local _server: any = nil
    local _client: any = nil

    local function getServer(): any
        if not _server then
            _server = require(script.Parent.Parent.transport.Server)
        end
        return _server
    end

    local function getClient(): any
        if not _client then
            _client = require(script.Parent.Parent.transport.Client)
        end
        return _client
    end

    local handle: any = {}

    function handle.send(self: PacketHandle, data: any, target: any?): ()
        if Middleware.hasSendHooks() then
            data = Middleware.runSend(data, name, nil)
            if typeof(data) == "table" and (data :: any)._lyncDrop then
                return
            end
        end

        if IS_SERVER then
            if target == nil then
                error(`[Lync] Packet "{name}": server send requires a target`)
            end

            local Server = getServer()

            if typeof(target) == "Instance" and target:IsA("Player") then
                local ch = Server.getChannel(target :: Player, isUnreliable)
                Channel.writeBatch(ch, reg, data)
                if Channel.statsEnabled() then
                    reg.fires += 1
                end
                return
            end

            if typeof(target) == "table" then
                local tbl = target :: any

                if tbl._lyncAll then
                    for _, player in Players:GetPlayers() do
                        local ch = Server.getChannel(player, isUnreliable)
                        Channel.writeBatch(ch, reg, data)
                    end
                    if Channel.statsEnabled() then
                        reg.fires += 1
                    end
                    return
                end

                if tbl._lyncExcept then
                    local excluded = tbl._excluded :: { [Player]: boolean }
                    for _, player in Players:GetPlayers() do
                        if not excluded[player] then
                            local ch = Server.getChannel(player, isUnreliable)
                            Channel.writeBatch(ch, reg, data)
                        end
                    end
                    if Channel.statsEnabled() then
                        reg.fires += 1
                    end
                    return
                end

                if tbl._lyncGroup then
                    local members = tbl._members :: { [Player]: boolean }
                    for player in members do
                        local ch = Server.getChannel(player, isUnreliable)
                        Channel.writeBatch(ch, reg, data)
                    end
                    if Channel.statsEnabled() then
                        reg.fires += 1
                    end
                    return
                end

                for _, player in tbl do
                    if typeof(player) == "Instance" and (player :: Instance):IsA("Player") then
                        local ch = Server.getChannel(player :: Player, isUnreliable)
                        Channel.writeBatch(ch, reg, data)
                    end
                end
                if Channel.statsEnabled() then
                    reg.fires += 1
                end
                return
            end

            error(
                `[Lync] Packet "{name}": expected Player, table, Group, or Lync.all as target, got {typeof(
                    target
                )}`
            )
        else
            local Client = getClient()
            local ch = Client.getChannel(isUnreliable)
            Channel.writeBatch(ch, reg, data)
            if Channel.statsEnabled() then
                reg.fires += 1
            end
        end
    end

    function handle.on(_self: PacketHandle, fn: (...any) -> ()): Types.Connection
        return reg.signal:connect(fn)
    end

    function handle.once(_self: PacketHandle, fn: (...any) -> ()): Types.Connection
        local conn: Types.Connection
        conn = reg.signal:connect(function(...: any)
            conn:disconnect()
            fn(...)
        end)
        return conn
    end

    function handle.wait(_self: PacketHandle): ...any
        return reg.signal:wait()
    end

    function handle.name(_self: PacketHandle): string
        return reg.name
    end

    function handle.stats(_self: PacketHandle): Types.PacketStats
        return {
            bytesSent = reg.bytesSent,
            bytesReceived = reg.bytesReceived,
            fires = reg.fires,
            recvFires = reg.recvFires,
            drops = reg.drops,
        }
    end

    return table.freeze(handle)
end

return table.freeze(Packet)
