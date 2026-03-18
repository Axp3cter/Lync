--!strict
--!optimize 2
-- Server-side transport with batching, delta state, frame XOR.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Baseline = require(script.Parent.Parent.internal.Baseline)
local Bridge = require(script.Parent.Bridge)
local Channel = require(script.Parent.Parent.internal.Channel)
local Gate = require(script.Parent.Gate)
local Middleware = require(script.Parent.Parent.internal.Middleware)
local Pool = require(script.Parent.Parent.internal.Pool)
local Reader = require(script.Parent.Reader)
local Registry = require(script.Parent.Parent.internal.Registry)
local Types = require(script.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T> = Types.Codec<T>
type Registration = Types.Registration

local channelWriteBatch = Channel.writeBatch
local channelWriteBatchRaw = Channel.writeBatchRaw
local channelUpdateTimestamp = Channel.updateTimestamp
local channelStatsEnabled = Channel.statsEnabled

-- State ---------------------------------------------------------------

type PlayerStats = {
    bytesSent: number,
    bytesReceived: number,
}

type PlayerState = {
    reliable: ChannelState,
    unreliable: ChannelState,
    stats: PlayerStats,
}

local _players = {} :: { [Player]: PlayerState }
local _prevRecv = {} :: { [Player]: buffer }
local _isStarted = false
local _broadScratch = Channel.create()

-- Flush control
local _flushRate = 60
local _flushInterval = 1 / 60
local _useAccumulator = false
local _flushAccum = 0
local _flushedThisFrame = false

-- Timestamp
local _frameCounter: number = 0

-- Bandwidth strike counter
local _strikes = {} :: { [Player]: number }
local _softLimit = 16384
local _maxStrikes = 10

-- Packet capture
local _captureEnabled = false
local _captureLabel = ""
local _captureFrame = 0
local _captures = {} :: { any }

local MAX_HEX = 512 -- cap hex dump to first 512 bytes to keep capture size sane

local function bufToHex(buf: buffer, len: number): string
    local cap = math.min(len, MAX_HEX)
    local parts = table.create(cap)
    for i = 0, cap - 1 do
        parts[i + 1] = string.format("%02x", buffer.readu8(buf, i))
    end
    return table.concat(parts)
end

-- Private -------------------------------------------------------------

local function onPlayerAdded(player: Player): ()
    _players[player] = {
        reliable = Pool.acquire(),
        unreliable = Pool.acquire(),
        stats = { bytesSent = 0, bytesReceived = 0 },
    }
    _strikes[player] = 0
    Gate.onPlayerAdded(player)
end

local function onPlayerRemoving(player: Player): ()
    local state = _players[player]
    if not state then
        return
    end

    Pool.release(state.reliable)
    Pool.release(state.unreliable)
    _players[player] = nil
    _prevRecv[player] = nil
    _strikes[player] = nil

    Gate.onPlayerRemoved(player)
    Baseline.clearSource(player)
end

local function receive(player: Player, data: any, refs: any, applyXor: boolean): ()
    local buf = Reader.decodeIncoming(data)
    if not buf then
        return
    end

    local len = buffer.len(buf)
    local strikes = _strikes[player] or 0
    if len > _softLimit then
        strikes += 1
    else
        strikes = math.max(0, strikes - 1)
    end
    _strikes[player] = strikes
    if strikes > _maxStrikes then
        Gate.reportDrop(player, "bandwidth", "frame", nil)
        return
    end

    local raw: buffer
    if applyXor then
        raw = Channel.xorApply(buf, _prevRecv[player])
        _prevRecv[player] = raw
    else
        raw = buf
    end

    local safeRefs: { Instance }? = if typeof(refs) == "table" then refs else nil
    local ok, err = pcall(Reader.process, raw, safeRefs, player, 0)
    if not ok then
        warn(`[Lync] Read failed from {player.Name} ({player.UserId}): {err}`)
        strikes = (_strikes[player] or 0) + 1
        _strikes[player] = strikes
    end

    if channelStatsEnabled() then
        local state = _players[player]
        if state then
            state.stats.bytesReceived += buffer.len(raw)
        end
    end
end

local function flushChannel(remote: any, ch: ChannelState, target: Player, applyXor: boolean): ()
    if ch.cursor == 0 then
        return
    end

    local raw, refs = Channel.sealAndDump(ch)

    local xored: buffer? = nil
    if applyXor then
        xored = Channel.xorApply(raw, ch.prevDump)
        ch.prevDump = raw
        remote:FireClient(target, xored, refs)
    else
        remote:FireClient(target, raw, refs)
    end

    if _captureEnabled then
        _captureFrame += 1
        local rawLen = buffer.len(raw)
        table.insert(_captures, {
            label = _captureLabel,
            frame = _captureFrame,
            raw = bufToHex(raw, rawLen),
            xored = if xored then bufToHex(xored :: buffer, buffer.len(xored :: buffer)) else nil,
            bytes = rawLen,
            refs = #refs,
        })
    end

    if channelStatsEnabled() then
        local state = _players[target]
        if state then
            state.stats.bytesSent += buffer.len(raw)
        end
    end

    Channel.reset(ch)
end

local function flush(): ()
    if Channel.hasTimestamps() then
        _frameCounter = (_frameCounter + 1) % 256
        channelUpdateTimestamp(_frameCounter, 0, os.clock())
    end

    local reliable = Bridge.reliable
    local unreliable = Bridge.unreliable

    for player, state in _players do
        local ok, err = pcall(flushChannel, reliable, state.reliable, player, true)
        if not ok then
            warn(`[Lync] Flush failed for {player.Name} ({player.UserId}): {err}`)
            Channel.reset(state.reliable)
        end

        local ok2, err2 = pcall(flushChannel, unreliable, state.unreliable, player, false)
        if not ok2 then
            warn(`[Lync] Flush failed for {player.Name} ({player.UserId}): {err2}`)
            Channel.reset(state.unreliable)
        end
    end
end

-- No timestamp here: writeBatchRaw handles it in the batch header.
local function serializeBroadcast(reg: Registration, data: any): (number, { Instance }?)
    local scratch = _broadScratch
    scratch.cursor = 0
    table.clear(scratch.refs)
    Channel.setCurrentPacket(reg.name)
    reg.codec.write(scratch, data)

    local snapRefs = if #scratch.refs > 0 then table.clone(scratch.refs) else nil
    return scratch.cursor, snapRefs
end

local function prepareBroadcast(reg: Registration, data: any): (any, number, { Instance }?)
    local final: any
    if Middleware.hasSend then
        final = Middleware.runSend(data, reg.name, nil)
        if final == nil then
            return nil, 0, nil
        end
    else
        final = data
    end

    local snapLen, snapRefs = serializeBroadcast(reg, final)
    return final, snapLen, snapRefs
end

-- Broadcast fan-out: stats computed once from snapLen, not per-player (#7)
local function broadcastToAll(
    reg: Registration,
    data: any,
    isUnreliable: boolean,
    exceptSet: { [Player]: true }?
): ()
    local final, snapLen, snapRefs = prepareBroadcast(reg, data)
    if final == nil and data ~= nil then
        return
    end

    local scratchBuff = _broadScratch.buff
    local count = 0
    for player, state in _players do
        if exceptSet and exceptSet[player] then
            continue
        end
        local ch = if isUnreliable then state.unreliable else state.reliable
        channelWriteBatchRaw(ch, reg, scratchBuff, snapLen, snapRefs)
        count += 1
    end
    if channelStatsEnabled() and count > 0 then
        -- Header (3 bytes for id+count) + timestamp + payload per player
        local tsBytes = if reg.timestampMode == 1
            then 1
            elseif reg.timestampMode == 2 then 2
            elseif reg.timestampMode == 3 then 8
            else 0
        reg.bytesSent += (3 + tsBytes + snapLen) * count
        reg.fires += count
    end
end

local function broadcastToList(
    players: { Player },
    reg: Registration,
    data: any,
    isUnreliable: boolean
): ()
    local final, snapLen, snapRefs = prepareBroadcast(reg, data)
    if final == nil and data ~= nil then
        return
    end

    local scratchBuff = _broadScratch.buff
    local count = 0
    for _, player in players do
        local state = _players[player]
        if not state then
            continue
        end
        local ch = if isUnreliable then state.unreliable else state.reliable
        channelWriteBatchRaw(ch, reg, scratchBuff, snapLen, snapRefs)
        count += 1
    end
    if channelStatsEnabled() and count > 0 then
        local tsBytes = if reg.timestampMode == 1
            then 1
            elseif reg.timestampMode == 2 then 2
            elseif reg.timestampMode == 3 then 8
            else 0
        reg.bytesSent += (3 + tsBytes + snapLen) * count
        reg.fires += count
    end
end

local function broadcastToSet(
    set: { [Player]: true },
    reg: Registration,
    data: any,
    isUnreliable: boolean
): ()
    local final, snapLen, snapRefs = prepareBroadcast(reg, data)
    if final == nil and data ~= nil then
        return
    end

    local scratchBuff = _broadScratch.buff
    local count = 0
    for player in set do
        local state = _players[player]
        if not state then
            continue
        end
        local ch = if isUnreliable then state.unreliable else state.reliable
        channelWriteBatchRaw(ch, reg, scratchBuff, snapLen, snapRefs)
        count += 1
    end
    if channelStatsEnabled() and count > 0 then
        local tsBytes = if reg.timestampMode == 1
            then 1
            elseif reg.timestampMode == 2 then 2
            elseif reg.timestampMode == 3 then 8
            else 0
        reg.bytesSent += (3 + tsBytes + snapLen) * count
        reg.fires += count
    end
end

-- Public --------------------------------------------------------------

local Server = {}

function Server.start(): ()
    if _isStarted then
        return
    end
    _isStarted = true

    Bridge.setup()

    Players.PlayerAdded:Connect(onPlayerAdded)
    Players.PlayerRemoving:Connect(onPlayerRemoving)
    for _, player in Players:GetPlayers() do
        onPlayerAdded(player)
    end

    Bridge.reliable.OnServerEvent:Connect(function(player: Player, data: any, refs: any): ()
        receive(player, data, refs, true)
    end)
    Bridge.unreliable.OnServerEvent:Connect(function(player: Player, data: any, refs: any): ()
        receive(player, data, refs, false)
    end)

    if _useAccumulator then
        RunService.Heartbeat:Connect(function(dt: number)
            if _flushedThisFrame then
                _flushedThisFrame = false
                return
            end
            _flushAccum += dt
            if _flushAccum < _flushInterval then
                return
            end
            _flushAccum -= _flushInterval
            flush()
        end)
    else
        RunService.Heartbeat:Connect(function()
            if _flushedThisFrame then
                _flushedThisFrame = false
                return
            end
            flush()
        end)
    end
end

function Server.writeTo(player: Player, reg: Registration, data: any, isUnreliable: boolean): ()
    local state = _players[player]
    if not state then
        return
    end

    local final: any
    if Middleware.hasSend then
        final = Middleware.runSend(data, reg.name, player)
        if final == nil then
            return
        end
    else
        final = data
    end

    local ch = if isUnreliable then state.unreliable else state.reliable
    if channelStatsEnabled() then
        local before = ch.cursor
        channelWriteBatch(ch, reg, final)
        reg.bytesSent += ch.cursor - before
        reg.fires += 1
    else
        channelWriteBatch(ch, reg, final)
    end
end

function Server.writeToAll(reg: Registration, data: any, isUnreliable: boolean): ()
    broadcastToAll(reg, data, isUnreliable, nil)
end

function Server.writeToList(
    players: { Player },
    reg: Registration,
    data: any,
    isUnreliable: boolean
): ()
    broadcastToList(players, reg, data, isUnreliable)
end

function Server.writeToAllExcept(
    exceptSet: { [Player]: true },
    reg: Registration,
    data: any,
    isUnreliable: boolean
): ()
    broadcastToAll(reg, data, isUnreliable, exceptSet)
end

function Server.writeToSet(
    set: { [Player]: true },
    reg: Registration,
    data: any,
    isUnreliable: boolean
): ()
    broadcastToSet(set, reg, data, isUnreliable)
end

function Server.writeQuery(
    player: Player,
    id: number,
    name: string,
    correlationId: number,
    codec: Codec<any>,
    data: any
): ()
    local state = _players[player]
    if not state then
        return
    end

    local final: any
    if Middleware.hasSend then
        final = Middleware.runSend(data, name, player)
        if final == nil then
            return
        end
    else
        final = data
    end

    Channel.writeQuery(state.reliable, id, name, correlationId, codec, final)
end

function Server.writeQueryNil(player: Player, id: number, name: string, correlationId: number): ()
    local state = _players[player]
    if not state then
        return
    end

    Channel.writeQuery(state.reliable, id, name, correlationId, nil, nil)
end

function Server.flush(): ()
    _flushAccum = 0
    _flushedThisFrame = true
    flush()
end

function Server.setFlushRate(hz: number): ()
    _flushRate = math.clamp(hz, 1, 60)
    _flushInterval = 1 / _flushRate
    _useAccumulator = _flushRate < 60
end

function Server.getFlushRate(): number
    return _flushRate
end

function Server.setBandwidthLimit(softLimit: number, maxStrikes: number): ()
    _softLimit = softLimit
    _maxStrikes = maxStrikes
end

function Server.getPlayerStats(player: Player): PlayerStats?
    local state = _players[player]
    return if state then state.stats else nil
end

function Server.resetStats(): ()
    for _, state in _players do
        state.stats.bytesSent = 0
        state.stats.bytesReceived = 0
    end
    Registry.forEach(function(reg: Registration)
        reg.bytesSent = 0
        reg.bytesReceived = 0
        reg.fires = 0
        reg.recvFires = 0
        reg.drops = 0
    end)
end

function Server.startCapture(label: string?): ()
    _captureEnabled = true
    _captureLabel = label or "unknown"
    _captureFrame = 0
end

function Server.stopCapture(): ()
    _captureEnabled = false
end

function Server.dumpCaptures(): ()
    local json = game:GetService("HttpService"):JSONEncode(_captures)
    local storage = game:GetService("ServerStorage")

    -- Clean up previous captures
    local old = storage:FindFirstChild("LyncCapture")
    if old then
        old:Destroy()
    end

    -- Split across StringValues if needed (200K limit per value)
    local CHUNK = 199000
    if #json <= CHUNK then
        local sv = Instance.new("StringValue")
        sv.Name = "LyncCapture"
        sv.Value = json
        sv.Parent = storage
    else
        local folder = Instance.new("Folder")
        folder.Name = "LyncCapture"
        local parts = math.ceil(#json / CHUNK)
        for i = 1, parts do
            local sv = Instance.new("StringValue")
            sv.Name = `Part{i}`
            sv.Value = string.sub(json, (i - 1) * CHUNK + 1, i * CHUNK)
            sv.Parent = folder
        end
        folder.Parent = storage
    end

    local count = #_captures
    table.clear(_captures)
    print(
        `[Lync] Capture saved: {count} entries, {#json} chars -> ServerStorage.LyncCapture (open in script editor, copy contents)`
    )
end

return table.freeze(Server)
