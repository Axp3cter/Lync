--!strict
--!optimize 2
-- Server-side transport with batching, delta state, frame XOR.

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

-- Constants --------------------------------------------------------------

local MAX_INCOMING = 65536

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

local function decodeIncoming (data: any): buffer?
    if typeof (data) ~= "buffer" then
        return nil
    end
    if buffer.len (data) > MAX_INCOMING then
        return nil
    end
    return data
end

local function receiveReliable (player: Player, data: any, refs: any): ()
    local buf = decodeIncoming (data)
    if not buf then
        return
    end

    local raw = Channel.xorApply (buf, _prevRecv[player])
    _prevRecv[player] = raw

    local safeRefs: { Instance }? = if typeof (refs) == "table" then refs else nil
    local ok, err = pcall (Reader.process, raw, safeRefs, player, 0)
    if not ok then
        warn (`[Lync] Reliable read failed from {player.Name} ({player.UserId}): {err}`)
    end
end

local function receiveUnreliable (player: Player, data: any, refs: any): ()
    local buf = decodeIncoming (data)
    if not buf then
        return
    end

    local safeRefs: { Instance }? = if typeof (refs) == "table" then refs else nil
    local ok, err = pcall (Reader.process, buf, safeRefs, player, 0)
    if not ok then
        warn (`[Lync] Unreliable read failed from {player.Name} ({player.UserId}): {err}`)
    end
end

local function flushChannel (remote: any, ch: ChannelState, target: Player, applyXor: boolean): ()
    if ch.cursor == 0 then
        return
    end

    Channel.seal (ch)

    local raw, refs = Channel.dump (ch)

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
    local reliable = Bridge.reliable ()
    local unreliable = Bridge.unreliable ()

    for player, state in _players do
        flushChannel (reliable, state.reliable, player, true)
        flushChannel (unreliable, state.unreliable, player, false)
    end
end

-- Serialize data once into shared scratch, return raw bytes + refs snapshot.
local function serializeBroadcast (codec: Codec<any>, data: any): (number, { Instance }?)
    local scratch = _broadScratch
    scratch.cursor = 0
    table.clear (scratch.refs)
    codec.write (scratch, data)

    local snapRefs = if #scratch.refs > 0 then table.clone (scratch.refs) else nil
    return scratch.cursor, snapRefs
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

    Bridge.reliable ().OnServerEvent:Connect (receiveReliable)
    Bridge.unreliable ().OnServerEvent:Connect (receiveUnreliable)
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

    local final = Middleware.runSend (data, name, player)
    if final == nil then
        return
    end

    local ch = if isUnreliable then state.unreliable else state.reliable
    Channel.writeBatch (ch, id, codec, final)
end

function Server.writeToAll (
    id: number,
    name: string,
    codec: Codec<any>,
    data: any,
    isUnreliable: boolean
): ()
    local final = Middleware.runSend (data, name, nil)
    if final == nil then
        return
    end

    local snapLen, snapRefs = serializeBroadcast (codec, final)

    for player, state in _players do
        local ch = if isUnreliable then state.unreliable else state.reliable
        Channel.writeBatchRaw (ch, id, _broadScratch.buff, snapLen, snapRefs)
    end
end

function Server.writeToList (
    players: { Player },
    id: number,
    name: string,
    codec: Codec<any>,
    data: any,
    isUnreliable: boolean
): ()
    local final = Middleware.runSend (data, name, nil)
    if final == nil then
        return
    end

    local snapLen, snapRefs = serializeBroadcast (codec, final)

    for _, player in players do
        local state = _players[player]
        if state then
            local ch = if isUnreliable then state.unreliable else state.reliable
            Channel.writeBatchRaw (ch, id, _broadScratch.buff, snapLen, snapRefs)
        end
    end
end

function Server.writeToAllExcept (
    except: Player,
    id: number,
    name: string,
    codec: Codec<any>,
    data: any,
    isUnreliable: boolean
): ()
    local final = Middleware.runSend (data, name, nil)
    if final == nil then
        return
    end

    local snapLen, snapRefs = serializeBroadcast (codec, final)

    for player, state in _players do
        if player == except then
            continue
        end

        local ch = if isUnreliable then state.unreliable else state.reliable
        Channel.writeBatchRaw (ch, id, _broadScratch.buff, snapLen, snapRefs)
    end
end

function Server.writeToGroup (
    groupName: string,
    id: number,
    name: string,
    codec: Codec<any>,
    data: any,
    isUnreliable: boolean
): ()
    local final = Middleware.runSend (data, name, nil)
    if final == nil then
        return
    end

    local snapLen, snapRefs = serializeBroadcast (codec, final)

    for player in Group.getSet (groupName) do
        local state = _players[player]
        if state then
            local ch = if isUnreliable then state.unreliable else state.reliable
            Channel.writeBatchRaw (ch, id, _broadScratch.buff, snapLen, snapRefs)
        end
    end
end

function Server.writeQueryResponse (
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

    local final = Middleware.runSend (data, name, player)
    if final == nil then
        return
    end

    local ch = state.reliable
    Channel.seal (ch)
    Channel.alloc (ch, 2)
    buffer.writeu8 (ch.buff, ch.cursor, id)
    buffer.writeu8 (ch.buff, ch.cursor + 1, correlationId)
    ch.cursor += 2
    codec.write (ch, final)
    ch.lastId = -1
end

return table.freeze (Server)
