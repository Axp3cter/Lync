--!strict
--!optimize 2
-- Server-side transport: per-player channels, broadcast, flush.

local Players = game:GetService("Players")

local Baseline = require(script.Parent.Parent.internal.Baseline)
local Bridge = require(script.Parent.Parent.transport.Bridge)
local Channel = require(script.Parent.Parent.internal.Channel)
local Gate = require(script.Parent.Parent.transport.Gate)
local Pool = require(script.Parent.Parent.internal.Pool)
local Reader = require(script.Parent.Parent.transport.Reader)
local Types = require(script.Parent.Parent.Types)

-- State ---------------------------------------------------------------

local _reliableChannels: { [Player]: Types.ChannelState } = {}
local _unreliableChannels: { [Player]: Types.ChannelState } = {}
local _playerStats: { [Player]: Types.PlayerStats } = {}
local _statsEnabled = false

-- Private -------------------------------------------------------------

local function getReliable(player: Player): Types.ChannelState
    local ch = _reliableChannels[player]
    if not ch then
        ch = Pool.acquire()
        _reliableChannels[player] = ch
    end
    return ch
end

local function getUnreliable(player: Player): Types.ChannelState
    local ch = _unreliableChannels[player]
    if not ch then
        ch = Pool.acquire()
        _unreliableChannels[player] = ch
    end
    return ch
end

local function flushPlayer(player: Player): ()
    -- Reliable channel
    local rCh = _reliableChannels[player]
    if rCh and rCh.cursor > 0 then
        local snapshot, refs, byteLen, refCount = Channel.sealAndDump(rCh)

        -- XOR against previous frame
        local xored = Channel.xorApply(snapshot, byteLen, rCh.prevDump, rCh.prevDumpLen)
        rCh.prevDump = snapshot
        rCh.prevDumpLen = byteLen

        Bridge.fireClient(player, xored, refs)
        Channel.reset(rCh)

        if _statsEnabled then
            local ps = _playerStats[player]
            if ps then
                ps.bytesSent += byteLen
            end
        end
    end

    -- Unreliable channel (no XOR, no delta)
    local uCh = _unreliableChannels[player]
    if uCh and uCh.cursor > 0 then
        local snapshot, refs, byteLen, _ = Channel.sealAndDump(uCh)

        Bridge.fireClientUnreliable(player, snapshot, refs)
        Channel.reset(uCh)

        if _statsEnabled then
            local ps = _playerStats[player]
            if ps then
                ps.bytesSent += byteLen
            end
        end
    end
end

-- Public --------------------------------------------------------------

local Server = {}

function Server.getChannel(player: Player, isUnreliable: boolean): Types.ChannelState
    return if isUnreliable then getUnreliable(player) else getReliable(player)
end

function Server.flush(): ()
    if Channel.hasTimestamps() then
        Channel.updateTimestamp()
    end

    for player in _reliableChannels do
        flushPlayer(player)
    end

    for player in _unreliableChannels do
        if not _reliableChannels[player] then
            flushPlayer(player)
        end
    end
end

function Server.flushPlayer(player: Player): ()
    flushPlayer(player)
end

function Server.start(): ()
    local container = Instance.new("Folder")
    container.Name = "LyncRemotes"
    container.Parent = game:GetService("ReplicatedStorage")

    Bridge.setup(container)

    local reliable = Bridge.reliable()
    local unreliable = Bridge.unreliable()

    -- Incoming reliable
    reliable.OnServerEvent:Connect(function(player: Player, data: any, refs: any?)
        local incoming = Reader.decodeIncoming(data)
        if not incoming then
            return
        end

        local incomingLen = buffer.len(incoming)

        -- Bandwidth check
        if not Gate.checkBandwidth(player, incomingLen) then
            return
        end

        -- XOR decode against player's previous outbound (client→server has no XOR)
        local ok, err = pcall(Reader.process, incoming, incomingLen, refs :: any, player, true)
        if not ok then
            warn(`[Lync] Server: read error from {player.Name}: {err}`)
        end

        if _statsEnabled then
            local ps = _playerStats[player]
            if ps then
                ps.bytesReceived += incomingLen
            end
        end
    end)

    -- Incoming unreliable
    unreliable.OnServerEvent:Connect(function(player: Player, data: any, refs: any?)
        local incoming = Reader.decodeIncoming(data)
        if not incoming then
            return
        end

        local incomingLen = buffer.len(incoming)

        local ok, err = pcall(Reader.process, incoming, incomingLen, refs :: any, player, true)
        if not ok then
            warn(`[Lync] Server: read error (unreliable) from {player.Name}: {err}`)
        end

        if _statsEnabled then
            local ps = _playerStats[player]
            if ps then
                ps.bytesReceived += incomingLen
            end
        end
    end)

    -- Player lifecycle
    Players.PlayerAdded:Connect(function(player: Player)
        if _statsEnabled then
            _playerStats[player] = { bytesSent = 0, bytesReceived = 0 }
        end
    end)

    Players.PlayerRemoving:Connect(function(player: Player)
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
        Gate.clearPlayer(player)
        Baseline.clearPlayer(player)
    end)

    -- Initialize stats for existing players
    if _statsEnabled then
        for _, player in Players:GetPlayers() do
            _playerStats[player] = { bytesSent = 0, bytesReceived = 0 }
        end
    end
end

function Server.enableStats(): ()
    _statsEnabled = true
end

function Server.getPlayerStats(player: Player): Types.PlayerStats?
    return _playerStats[player]
end

function Server.resetStats(): ()
    for player, ps in _playerStats do
        ps.bytesSent = 0
        ps.bytesReceived = 0
    end
end

return table.freeze(Server)
