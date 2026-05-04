--!strict
--!optimize 2
-- Packet definition: send, on, once, wait, stats.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Baseline = require(script.Parent.Parent.internal.Baseline)
local Channel = require(script.Parent.Parent.internal.Channel)
local Log = require(script.Parent.Parent.util.Log)
local Middleware = require(script.Parent.Parent.internal.Middleware)
local Player = require(script.Parent.Parent.util.Player)
local Registry = require(script.Parent.Parent.internal.Registry)
local Shared = require(script.Parent.Parent.codec.composite.Shared)
local Transport = require(script.Parent.Parent.internal.Transport)
local Types = require(script.Parent.Parent.Types)

-- Constants --------------------------------------------------------------

local IS_SERVER = RunService:IsServer()

-- mode: TS_* tag; headerSize: 1 (frame byte) + timestamp bytes (1, 2, or 8).
local TS_MODES: { [string]: { mode: number, headerSize: number } } = table.freeze({
    frame = table.freeze({ mode = Channel.TS_FRAME, headerSize = 2 }),
    offset = table.freeze({ mode = Channel.TS_OFFSET, headerSize = 3 }),
    full = table.freeze({ mode = Channel.TS_FULL, headerSize = 9 }),
})

local EMPTY_OPTIONS: Types.PacketOptions = table.freeze({})

-- Private ----------------------------------------------------------------

local isPlayer = Player.is

local function resolveTimestampMode(ts: ("frame" | "offset" | "full")?): (number, number)
    if ts == nil then
        return Channel.TS_NONE, 1
    end
    local entry = TS_MODES[ts]
    Channel.enableTimestamps()
    return entry.mode, entry.headerSize
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
    local opts = options or EMPTY_OPTIONS
    local isUnreliable = opts.unreliable or false

    -- Delta + unreliable is unsafe: a dropped frame permanently desyncs the receiver baseline.
    if isUnreliable and codec._isDelta then
        Log.error(
            `"{name}" delta codecs need reliable transport (lost packets desync the baseline)`
        )
    end

    if codec._hasUnknown and not opts.validate then
        Log.warn(`"{name}" uses unknown codec without validate; data bypasses schema validation`)
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

    --[[
        Run the send middleware chain. Returns (dropped, value). A nil value
        is a legitimate payload (Lync.nothing); only the explicit Lync.DROP
        sentinel or a hook returning DROP triggers the drop branch.
    ]]
    local function applySend(data: any, player: Player?): (boolean, any)
        if not Middleware.hasSendHooks() then
            return false, data
        end
        local sendData = Middleware.runSend(data, name, player)
        if typeof(sendData) == "table" and sendData._lyncKind == "drop" then
            return true, nil
        end
        return false, sendData
    end

    -- Non-delta codecs are stateless wire-encoders, so broadcast can encode
    -- once and bufCopy the payload to every player. Falls through if the
    -- encoded payload includes ref indices (the indices would need rewriting
    -- per channel, which no codec exposes).
    local canEncodeOnce = not codec._isDelta and not codec._hasDelta

    local function broadcast(players: { Player }, data: any): ()
        local count = #players
        if count == 0 then
            bumpFires()
            return
        end

        if canEncodeOnce then
            local scratch = Shared.acquireScratch()
            scratch.currentPacket = name
            codec.write(scratch, data)
            scratch.currentPacket = nil
            if scratch.refCount == 0 then
                local payload = scratch.buff
                local payloadLen = scratch.cursor
                local server = Transport.server()
                local getChannel = if isUnreliable
                    then server.getUnreliableChannel
                    else server.getReliableChannel
                -- Channel.writeBatchEncoded is hot-swapped by enableStats; re-read per call.
                local writeBatchEncoded = Channel.writeBatchEncoded
                for i = 1, count do
                    writeBatchEncoded(getChannel(players[i]), reg, payload, payloadLen)
                end
                Shared.releaseScratch()
                bumpFires()
                return
            end
            Shared.releaseScratch()
        end

        for i = 1, count do
            sendToPlayer(players[i], data)
        end
        bumpFires()
    end

    --[[
        Resolve a target table into a { Player } list. Returns nil for unknown
        sentinel kinds; the caller errors with the original target type.
    ]]
    local function resolveAudience(target: any): { Player }?
        local kind = target._lyncKind
        if kind == "all" then
            return Players:GetPlayers()
        end

        if kind == "except" then
            local excluded = target._excluded :: { [Player]: boolean }
            local all = Players:GetPlayers()
            local list = table.create(#all)
            local n = 0
            for _, player in all do
                if not excluded[player] then
                    n += 1
                    list[n] = player
                end
            end
            return list
        end

        if kind == "group" then
            local members = target._members :: { [Player]: boolean }
            local list: { Player } = {}
            local n = 0
            for player in members do
                n += 1
                list[n] = player
            end
            return list
        end

        if kind == nil then
            -- Plain { Player } array. Validate entries on the way to a clean list.
            local list: { Player } = {}
            local n = 0
            for _, player in target do
                if isPlayer(player) then
                    n += 1
                    list[n] = player :: Player
                end
            end
            return list
        end

        return nil
    end

    local function sendToTarget(data: any, target: any): ()
        if isPlayer(target) then
            local dropped, sendData = applySend(data, target :: Player)
            if dropped then
                return
            end
            sendToPlayer(target :: Player, sendData)
            bumpFires()
            return
        end

        if typeof(target) == "table" then
            local dropped, sendData = applySend(data, nil)
            if dropped then
                return
            end
            local audience = resolveAudience(target)
            if audience then
                broadcast(audience, sendData)
                return
            end
        end

        Log.error(`"{name}" expected Player, table, Group, or Lync.all, got {typeof(target)}`)
    end

    local function sendFromServer(data: any, target: any): ()
        if target == nil then
            Log.error(`"{name}" server send requires a target`)
        end
        sendToTarget(data, target)
    end

    local function sendFromClient(data: any): ()
        local dropped, sendData = applySend(data, nil)
        if dropped then
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
