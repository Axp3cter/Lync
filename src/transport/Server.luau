--!strict
--!optimize 2
-- Server.luau — Server-side transport with per-player channels and frame batching.

local Players = game:GetService ("Players")
local RunService = game:GetService ("RunService")

local Bridge = require (script.Parent.Bridge)
local Channel = require (script.Parent.Parent.core.Channel)
local Compress = require (script.Parent.Compress)
local Gate = require (script.Parent.Gate)
local Middleware = require (script.Parent.Parent.core.Middleware)
local Pool = require (script.Parent.Parent.core.Pool)
local Reader = require (script.Parent.Reader)
local Types = require (script.Parent.Parent.Types)
local Varint = require (script.Parent.Parent.core.Varint)

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
local _isStarted = false

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

    Gate.onPlayerRemoved (player)
end

local function receive (player: Player, data: any, refs: any, compressed: any): ()
    if typeof (data) ~= "buffer" then
        return
    end
    if buffer.len (data) > MAX_INCOMING then
        return
    end

    local buf: buffer
    if compressed == true then
        local ok, result = pcall (Compress.unpack, data)
        if not ok then
            return
        end
        buf = result
    else
        buf = data
    end

    local safeRefs: { Instance }? = if typeof (refs) == "table" then refs else nil
    local ok, err = pcall (Reader.process, buf, safeRefs, player, 0)
    if not ok then
        warn (`[Lync] Bad buffer from {player.Name}: {err}`)
    end
end

local function writeRaw (ch: ChannelState, id: number, codec: Codec<any>, data: any): ()
    Varint.write (ch, id)
    codec.write (ch, data)
end

local function selectChannel (state: PlayerState, reliability: string): ChannelState
    return if reliability == "unreliable" then state.unreliable else state.reliable
end

local function flushChannel (remote: any, ch: ChannelState, target: Player): ()
    if ch.cursor == 0 then
        return
    end

    local buf, refs = Channel.dump (ch)
    local packed, wasCompressed = Compress.pack (buf)

    if wasCompressed then
        remote:FireClient (target, packed, refs, true)
    else
        remote:FireClient (target, packed, refs)
    end

    Channel.reset (ch)
end

local function flush (): ()
    local reliable = Bridge.reliable ()
    local unreliable = Bridge.unreliable ()

    for player, state in _players do
        flushChannel (reliable, state.reliable, player)
        flushChannel (unreliable, state.unreliable, player)
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
    Pool.warmup (16)

    Players.PlayerAdded:Connect (onPlayerAdded)
    Players.PlayerRemoving:Connect (onPlayerRemoving)
    for _, player in Players:GetPlayers () do
        onPlayerAdded (player)
    end

    Bridge.reliable ().OnServerEvent:Connect (receive)
    Bridge.unreliable ().OnServerEvent:Connect (receive)
    RunService.Heartbeat:Connect (flush)
end

function Server.writeTo (
    player: Player,
    id: number,
    name: string,
    codec: Codec<any>,
    data: any,
    reliability: string
): ()
    local state = _players[player]
    if not state then
        return
    end

    local final = Middleware.runSend (data, name, player)
    if final == nil then
        return
    end

    writeRaw (selectChannel (state, reliability), id, codec, final)
end

function Server.writeToAll (
    id: number,
    name: string,
    codec: Codec<any>,
    data: any,
    reliability: string
): ()
    local final = Middleware.runSend (data, name, nil)
    if final == nil then
        return
    end

    for _, player in Players:GetPlayers () do
        local state = _players[player]
        if state then
            writeRaw (selectChannel (state, reliability), id, codec, final)
        end
    end
end

function Server.writeToList (
    players: { Player },
    id: number,
    name: string,
    codec: Codec<any>,
    data: any,
    reliability: string
): ()
    local final = Middleware.runSend (data, name, nil)
    if final == nil then
        return
    end

    for _, player in players do
        local state = _players[player]
        if state then
            writeRaw (selectChannel (state, reliability), id, codec, final)
        end
    end
end

function Server.writeToAllExcept (
    except: Player,
    id: number,
    name: string,
    codec: Codec<any>,
    data: any,
    reliability: string
): ()
    local final = Middleware.runSend (data, name, nil)
    if final == nil then
        return
    end

    for _, player in Players:GetPlayers () do
        if player == except then
            continue
        end

        local state = _players[player]
        if state then
            writeRaw (selectChannel (state, reliability), id, codec, final)
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
    Varint.write (ch, id)
    Channel.alloc (ch, 1)
    buffer.writeu8 (ch.buff, ch.cursor, correlationId)
    ch.cursor += 1
    codec.write (ch, final)
end

return table.freeze (Server)
