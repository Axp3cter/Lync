--!strict
--!optimize 2
-- Server transport: per-player channels, broadcast, flush.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Baseline = require(script.Parent.Parent.internal.Baseline)
local Bridge = require(script.Parent.Parent.transport.Bridge)
local Channel = require(script.Parent.Parent.internal.Channel)
local Gate = require(script.Parent.Parent.transport.Gate)
local Pool = require(script.Parent.Parent.internal.Pool)
local Reader = require(script.Parent.Parent.transport.Reader)
local Types = require(script.Parent.Parent.Types)

-- Constants --------------------------------------------------------------

local CONTAINER_NAME = "LyncRemotes"

-- State ------------------------------------------------------------------

local _reliableChannels: { [Player]: Types.ChannelState } = {}
local _unreliableChannels: { [Player]: Types.ChannelState } = {}
local _playerStats: { [Player]: Types.PlayerStats } = {}
local _prevIncoming: { [Player]: buffer } = {}
local _prevIncomingLen: { [Player]: number } = {}

-- Private ----------------------------------------------------------------

local statsEnabled = Channel.statsEnabled
local xorApply = Channel.xorApply
local sealAndDump = Channel.sealAndDump
local resetCh = Channel.reset

local function getOrCreateChannel(
    map: { [Player]: Types.ChannelState },
    player: Player
): Types.ChannelState
    local ch = map[player]
    if not ch then
        ch = Pool.acquire()
        map[player] = ch
    end
    return ch
end

-- Hot-swapped at Server.start; stats-off path is a tail-callable noop.
local function noopStat(_player: Player, _byteLen: number): () end

local function realBytesSent(player: Player, byteLen: number): ()
    local ps = _playerStats[player]
    if ps then
        ps.bytesSent += byteLen
    end
end

local function realBytesReceived(player: Player, byteLen: number): ()
    local ps = _playerStats[player]
    if ps then
        ps.bytesReceived += byteLen
    end
end

local addBytesSent: (Player, number) -> () = noopStat
local addBytesReceived: (Player, number) -> () = noopStat

local function flushReliable(player: Player): ()
    local rCh = _reliableChannels[player]
    if not rCh or rCh.cursor == 0 then
        return
    end

    local snapshot, refs, byteLen = sealAndDump(rCh)
    local xored = xorApply(snapshot, byteLen, rCh.prevDump, rCh.prevDumpLen)
    rCh.prevDump = snapshot
    rCh.prevDumpLen = byteLen

    Bridge.fireClient(player, xored, refs)
    resetCh(rCh)
    addBytesSent(player, byteLen)
end

local function flushUnreliable(player: Player): ()
    local uCh = _unreliableChannels[player]
    if not uCh or uCh.cursor == 0 then
        return
    end

    local snapshot, refs, byteLen = sealAndDump(uCh)
    Bridge.fireClientUnreliable(player, snapshot, refs)
    resetCh(uCh)
    addBytesSent(player, byteLen)
end

local function flushPlayer(player: Player): ()
    flushReliable(player)
    flushUnreliable(player)
end

local function handleIncomingReliable(player: Player, data: any, refs: any?): ()
    local incoming = Reader.decodeIncoming(data)
    if not incoming then
        return
    end

    local incomingLen = buffer.len(incoming)
    if not Gate.checkBandwidth(player, incomingLen) then
        return
    end

    local prev = _prevIncoming[player]
    local decoded = xorApply(incoming, incomingLen, prev, _prevIncomingLen[player])

    --[[
        Only adopt `decoded` as the next XOR baseline on success. A failed
        parse means the wire is suspect; reusing it would poison every
        subsequent packet.
    ]]
    if Reader.process(decoded, incomingLen, refs, player, true) then
        _prevIncoming[player] = decoded
        _prevIncomingLen[player] = incomingLen
    else
        _prevIncoming[player] = nil
        _prevIncomingLen[player] = nil
    end

    addBytesReceived(player, incomingLen)
end

local function handleIncomingUnreliable(player: Player, data: any, refs: any?): ()
    local incoming = Reader.decodeIncoming(data)
    if not incoming then
        return
    end

    local incomingLen = buffer.len(incoming)
    Reader.process(incoming, incomingLen, refs, player, true)
    addBytesReceived(player, incomingLen)
end

local function clearPlayerState(player: Player): ()
    local rCh = _reliableChannels[player]
    if rCh then
        _reliableChannels[player] = nil
        Pool.release(rCh)
    end
    local uCh = _unreliableChannels[player]
    if uCh then
        _unreliableChannels[player] = nil
        Pool.release(uCh)
    end

    _playerStats[player] = nil
    _prevIncoming[player] = nil
    _prevIncomingLen[player] = nil

    Gate.clearPlayer(player)
    Baseline.clearPlayer(player)
end

-- Public -----------------------------------------------------------------

local Server = {}

function Server.getChannel(player: Player, isUnreliable: boolean): Types.ChannelState
    return getOrCreateChannel(
        if isUnreliable then _unreliableChannels else _reliableChannels,
        player
    )
end

-- Pre-resolved variants for broadcast: skip the per-audience-member isUnreliable branch.
function Server.getReliableChannel(player: Player): Types.ChannelState
    return getOrCreateChannel(_reliableChannels, player)
end

function Server.getUnreliableChannel(player: Player): Types.ChannelState
    return getOrCreateChannel(_unreliableChannels, player)
end

function Server.flush(): ()
    if Channel.hasTimestamps() then
        Channel.updateTimestamp()
    end
    for _, player in Players:GetPlayers() do
        flushPlayer(player)
    end
end

Server.flushPlayer = flushPlayer

function Server.start(): ()
    local container = Instance.new("Folder")
    container.Name = CONTAINER_NAME
    container.Parent = ReplicatedStorage

    Bridge.setup(container)

    Bridge.reliable().OnServerEvent:Connect(handleIncomingReliable)
    Bridge.unreliable().OnServerEvent:Connect(handleIncomingUnreliable)

    if statsEnabled() then
        addBytesSent = realBytesSent
        addBytesReceived = realBytesReceived
    end

    Players.PlayerAdded:Connect(function(player: Player)
        if statsEnabled() then
            _playerStats[player] = { bytesSent = 0, bytesReceived = 0 }
        end
    end)
    Players.PlayerRemoving:Connect(clearPlayerState)

    -- Catch players who joined before Lync.start.
    if statsEnabled() then
        for _, player in Players:GetPlayers() do
            _playerStats[player] = { bytesSent = 0, bytesReceived = 0 }
        end
    end
end

function Server.getPlayerStats(player: Player): Types.PlayerStats?
    return _playerStats[player]
end

function Server.resetStats(): ()
    for _, ps in _playerStats do
        ps.bytesSent = 0
        ps.bytesReceived = 0
    end
end

return table.freeze(Server)
