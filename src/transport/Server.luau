--!strict
--!optimize 2
-- Server.luau — Server-side transport with batching, delta state, frame XOR.

local Players = game:GetService ("Players")
local RunService = game:GetService ("RunService")

local Baseline = require (script.Parent.Parent.core.Baseline)
local Bridge = require (script.Parent.Bridge)
local Channel = require (script.Parent.Parent.core.Channel)
local Gate = require (script.Parent.Gate)
local Group = require (script.Parent.Parent.event.Group)
local Middleware = require (script.Parent.Parent.core.Middleware)
local Pool = require (script.Parent.Parent.core.Pool)
local Reader = require (script.Parent.Reader)
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T> = Types.Codec<T>

-- State ------------------------------------------------------------------

type PlayerState = {
    reliable: ChannelState,
    unreliable: ChannelState,
}

local _players = {} :: { [Player]: PlayerState }
local _prevRecv = {} :: { [Player]: buffer }
local _isStarted = false
local _broadScratch = Channel.create ()

-- Private ----------------------------------------------------------------

local function onPlayerAdded (player: Player): ()
    _players[player] = {
        reliable = Pool.acquire (),
        unreliable = Pool.acquire (),
    }
    Gate.onPlayerAdded (player)
end

local function onPlayerRemoving (player: Player): ()
    local state = _players[player]
    if not state then
        return
    end

    Pool.release (state.reliable)
    Pool.release (state.unreliable)
    _players[player] = nil
    _prevRecv[player] = nil

    Gate.onPlayerRemoved (player)
    Baseline.clearSource (player)
end

local function receive (player: Player, data: any, refs: any, applyXor: boolean): ()
    local buf = Reader.decodeIncoming (data)
    if not buf then
        return
    end

    local raw: buffer
    if applyXor then
        raw = Channel.xorApply (buf, _prevRecv[player])
        _prevRecv[player] = raw
    else
        raw = buf
    end

    local safeRefs: { Instance }? = if typeof (refs) == "table" then refs else nil
    local ok, err = pcall (Reader.process, raw, safeRefs, player, 0)
    if not ok then
        warn (`[Lync] Read failed from {player.Name} ({player.UserId}): {err}`)
    end
end

local function flushChannel (remote: any, ch: ChannelState, target: Player, applyXor: boolean): ()
    if ch.cursor == 0 then
        return
    end

    local raw, refs = Channel.sealAndDump (ch)

    if applyXor then
        local xored = Channel.xorApply (raw, ch.prevDump)
        ch.prevDump = raw
        remote:FireClient (target, xored, refs)
    else
        remote:FireClient (target, raw, refs)
    end

    Channel.reset (ch)
end

local function flush (): ()
    local reliable = Bridge.reliable
    local unreliable = Bridge.unreliable

    for player, state in _players do
        local ok, err = pcall (flushChannel, reliable, state.reliable, player, true)
        if not ok then
            warn (`[Lync] Flush failed for {player.Name} ({player.UserId}): {err}`)
            Channel.reset (state.reliable)
        end

        local ok2, err2 = pcall (flushChannel, unreliable, state.unreliable, player, false)
        if not ok2 then
            warn (`[Lync] Flush failed for {player.Name} ({player.UserId}): {err2}`)
            Channel.reset (state.unreliable)
        end
    end
end

-- Serialize data once into shared scratch, return raw bytes + refs snapshot.
local function serializeBroadcast (
    name: string,
    codec: Codec<any>,
    data: any
): (number, { Instance }?)
    local scratch = _broadScratch
    scratch.cursor = 0
    table.clear (scratch.refs)
    Channel.setCurrentPacket (name)
    codec.write (scratch, data)

    local snapRefs = if #scratch.refs > 0 then table.clone (scratch.refs) else nil
    return scratch.cursor, snapRefs
end

--[[
    Shared broadcast: middleware → serialize once → fan out to each player's
    channel. Accepts _players, a { Player } list, or a group set.
]]
local function broadcastTo (
    targets: { [any]: any },
    id: number,
    name: string,
    codec: Codec<any>,
    data: any,
    isUnreliable: boolean,
    except: Player?
): ()
    local final: any
    if Middleware.hasSend then
        final = Middleware.runSend (data, name, nil)
        if final == nil then
            return
        end
    else
        final = data
    end

    local snapLen, snapRefs = serializeBroadcast (name, codec, final)
    local scratchBuff = _broadScratch.buff

    -- Determine iteration mode from first key (once, not per entry)
    local firstKey = next (targets)
    if firstKey == nil then
        return
    end

    if type (firstKey) == "number" then
        -- Array path: { Player } — numeric keys, values are players
        for _, player in targets :: { any } do
            local state = _players[player]
            if not state or (except and player == except) then
                continue
            end
            local ch = if isUnreliable then state.unreliable else state.reliable
            Channel.writeBatchRaw (ch, id, scratchBuff, snapLen, snapRefs)
        end
    else
        -- Map path: { [Player]: PlayerState } or { [Player]: true }
        local firstIsState = type (targets[firstKey]) == "table"

        if firstIsState then
            -- _players map: value IS the PlayerState
            for player, state in targets :: { [any]: PlayerState } do
                if except and player == except then
                    continue
                end
                local ch = if isUnreliable then state.unreliable else state.reliable
                Channel.writeBatchRaw (ch, id, scratchBuff, snapLen, snapRefs)
            end
        else
            -- Group set: { [Player]: true } — look up state from _players
            for player in targets do
                local state = _players[player]
                if not state or (except and player == except) then
                    continue
                end
                local ch = if isUnreliable then state.unreliable else state.reliable
                Channel.writeBatchRaw (ch, id, scratchBuff, snapLen, snapRefs)
            end
        end
    end
end

-- Public -----------------------------------------------------------------

local Server = {}

function Server.start (): ()
    if _isStarted then
        return
    end
    _isStarted = true

    Bridge.setup ()

    Players.PlayerAdded:Connect (onPlayerAdded)
    Players.PlayerRemoving:Connect (onPlayerRemoving)
    for _, player in Players:GetPlayers () do
        onPlayerAdded (player)
    end

    Bridge.reliable.OnServerEvent:Connect (function (player: Player, data: any, refs: any): ()
        receive (player, data, refs, true)
    end)
    Bridge.unreliable.OnServerEvent:Connect (function (player: Player, data: any, refs: any): ()
        receive (player, data, refs, false)
    end)
    RunService.Heartbeat:Connect (flush)
end

function Server.writeTo (
    player: Player,
    id: number,
    name: string,
    codec: Codec<any>,
    data: any,
    isUnreliable: boolean
): ()
    local state = _players[player]
    if not state then
        return
    end

    local final: any
    if Middleware.hasSend then
        final = Middleware.runSend (data, name, player)
        if final == nil then
            return
        end
    else
        final = data
    end

    local ch = if isUnreliable then state.unreliable else state.reliable
    Channel.writeBatch (ch, id, name, codec, final)
end

function Server.writeToAll (
    id: number,
    name: string,
    codec: Codec<any>,
    data: any,
    isUnreliable: boolean
): ()
    broadcastTo (_players, id, name, codec, data, isUnreliable, nil)
end

function Server.writeToList (
    players: { Player },
    id: number,
    name: string,
    codec: Codec<any>,
    data: any,
    isUnreliable: boolean
): ()
    broadcastTo (players :: any, id, name, codec, data, isUnreliable, nil)
end

function Server.writeToAllExcept (
    except: Player,
    id: number,
    name: string,
    codec: Codec<any>,
    data: any,
    isUnreliable: boolean
): ()
    broadcastTo (_players, id, name, codec, data, isUnreliable, except)
end

function Server.writeToGroup (
    groupName: string,
    id: number,
    name: string,
    codec: Codec<any>,
    data: any,
    isUnreliable: boolean
): ()
    broadcastTo (Group.getSet (groupName) :: any, id, name, codec, data, isUnreliable, nil)
end

-- Shared for both query requests and responses (identical wire format).
function Server.writeQuery (
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
        final = Middleware.runSend (data, name, player)
        if final == nil then
            return
        end
    else
        final = data
    end

    Channel.writeQuery (state.reliable, id, name, correlationId, codec, final)
end

function Server.writeQueryNil (player: Player, id: number, name: string, correlationId: number): ()
    local state = _players[player]
    if not state then
        return
    end

    Channel.writeQuery (state.reliable, id, name, correlationId, nil, nil)
end

return table.freeze (Server)
