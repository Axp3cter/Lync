--!strict
--!optimize 2
-- Packet definition: send, on, once, wait, stats.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Baseline = require(script.Parent.Parent.internal.Baseline)
local Channel = require(script.Parent.Parent.internal.Channel)
local Middleware = require(script.Parent.Parent.internal.Middleware)
local Registry = require(script.Parent.Parent.internal.Registry)
local Transport = require(script.Parent.Parent.internal.Transport)
local Types = require(script.Parent.Parent.Types)
local Util = require(script.Parent.Parent.internal.Util)

-- Constants --------------------------------------------------------------

local IS_SERVER = RunService:IsServer()

-- Private ----------------------------------------------------------------

local isPlayer = Util.isPlayer

local function resolveTimestampMode(ts: ("frame" | "offset" | "full")?): (number, number)
    if ts == "frame" then
        Channel.enableTimestamps()
        return Channel.TS_FRAME, 2
    end
    if ts == "offset" then
        Channel.enableTimestamps()
        return Channel.TS_OFFSET, 3
    end
    if ts == "full" then
        Channel.enableTimestamps()
        return Channel.TS_FULL, 9
    end
    return Channel.TS_NONE, 1
end

-- Public types -----------------------------------------------------------

export type PacketHandle<T> = {
    send: (self: PacketHandle<T>, data: T, target: any?) -> (),
    on: (
        self: PacketHandle<T>,
        fn: (data: T, sender: Player?, timestamp: number?) -> ()
    ) -> Types.Connection,
    once: (
        self: PacketHandle<T>,
        fn: (data: T, sender: Player?, timestamp: number?) -> ()
    ) -> Types.Connection,
    wait: (self: PacketHandle<T>) -> (T, Player?, number?),
    name: (self: PacketHandle<T>) -> string,
    stats: (self: PacketHandle<T>) -> Types.PacketStats,
}

-- Public -----------------------------------------------------------------

local Packet = {}

function Packet.define<T>(
    name: string,
    codec: Types.InternalCodec<T>,
    options: Types.PacketOptions?
): PacketHandle<T>
    local opts = options or ({} :: Types.PacketOptions)
    local isUnreliable = opts.unreliable or false

    if isUnreliable and codec._isDelta then
        error(`[Lync] Lync.packet: "{name}" cannot use delta codecs with unreliable transport`)
    end

    if codec._hasUnknown and not opts.validate then
        warn(
            `[Lync] Lync.packet: "{name}" uses unknown codec without validate; data bypasses schema validation`
        )
    end

    if codec._isDelta then
        Baseline.markHasDelta()
    end

    local tsMode, headerSize = resolveTimestampMode(opts.timestamp)
    local openFn = Channel.resolveOpenFn(tsMode, name)

    local reg = Registry.register({
        name = name,
        kind = Registry.KIND_PACKET,
        codec = codec,
        isUnreliable = isUnreliable,
        partner = nil,
        needsGate = IS_SERVER,
        headerSize = headerSize,
        timestampMode = tsMode,
        openFn = openFn,
        rateLimit = opts.rateLimit,
        validate = opts.validate,
        maxPayloadBytes = opts.maxPayloadBytes,
    })

    local function sendToPlayer(player: Player, data: any): ()
        local ch = Transport.server().getChannel(player, isUnreliable)
        Channel.writeBatch(ch, reg, data)
    end

    local function bumpFires(): ()
        if Channel.statsEnabled() then
            reg.fires += 1
        end
    end

    local function applySend(data: any, player: Player?): any?
        if not Middleware.hasSendHooks() then
            return data
        end

        local sendData = Middleware.runSend(data, name, player)
        if typeof(sendData) == "table" and sendData._lyncDrop then
            return nil
        end
        return sendData
    end

    local function sendFromServer(data: any, target: any): ()
        if target == nil then
            error(`[Lync] Packet.send: "{name}" server send requires a target`)
        end

        if isPlayer(target) then
            local sendData = applySend(data, target :: Player)
            if sendData == nil then
                return
            end
            sendToPlayer(target :: Player, sendData)
            bumpFires()
            return
        end

        if typeof(target) == "table" then
            local sendData = applySend(data, nil)
            if sendData == nil then
                return
            end

            if target._lyncAll then
                for _, player in Players:GetPlayers() do
                    sendToPlayer(player, sendData)
                end
                bumpFires()
                return
            end

            if target._lyncExcept then
                local excluded = target._excluded :: { [Player]: boolean }
                for _, player in Players:GetPlayers() do
                    if not excluded[player] then
                        sendToPlayer(player, sendData)
                    end
                end
                bumpFires()
                return
            end

            if target._lyncGroup then
                for player in target._members :: { [Player]: boolean } do
                    sendToPlayer(player, sendData)
                end
                bumpFires()
                return
            end

            for _, player in target do
                if isPlayer(player) then
                    sendToPlayer(player :: Player, sendData)
                end
            end
            bumpFires()
            return
        end

        error(
            `[Lync] Packet.send: "{name}" expected Player, table, Group, or Lync.all as target, got {typeof(
                target
            )}`
        )
    end

    local function sendFromClient(data: any): ()
        local sendData = applySend(data, nil)
        if sendData == nil then
            return
        end
        local ch = Transport.client().getChannel(isUnreliable)
        Channel.writeBatch(ch, reg, sendData)
        bumpFires()
    end

    type Self = PacketHandle<T>
    type Listener = (data: T, sender: Player?, timestamp: number?) -> ()

    local handle = {
        send = function(_self: Self, data: T, target: any?): ()
            if IS_SERVER then
                sendFromServer(data, target)
            else
                sendFromClient(data)
            end
        end,

        on = function(_self: Self, fn: Listener): Types.Connection
            return reg.signal:connect(fn :: any)
        end,

        once = function(_self: Self, fn: Listener): Types.Connection
            local conn: Types.Connection
            conn = reg.signal:connect(function(...: any)
                conn:disconnect()
                fn(...)
            end)
            return conn
        end,

        wait = function(_self: Self): (T, Player?, number?)
            return reg.signal:wait()
        end,

        name = function(_self: Self): string
            return reg.name
        end,

        stats = function(_self: Self): Types.PacketStats
            return {
                bytesSent = reg.bytesSent,
                bytesReceived = reg.bytesReceived,
                fires = reg.fires,
                recvFires = reg.recvFires,
                drops = reg.drops,
            }
        end,
    }

    return table.freeze(handle) :: PacketHandle<T>
end

return table.freeze(Packet)
