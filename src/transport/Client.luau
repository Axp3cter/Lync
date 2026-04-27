--!strict
--!optimize 2
-- Client-side transport: single channel pair, flush, with outbound XOR delta.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Bridge = require(script.Parent.Parent.transport.Bridge)
local Channel = require(script.Parent.Parent.internal.Channel)
local Reader = require(script.Parent.Parent.transport.Reader)
local Types = require(script.Parent.Parent.Types)

-- Constants --------------------------------------------------------------

local CONTAINER_NAME = "LyncRemotes"

-- State ------------------------------------------------------------------

local _reliable: Types.ChannelState = Channel.create()
local _unreliable: Types.ChannelState = Channel.create()
local _prevIncoming: buffer? = nil
local _prevIncomingLen = 0

-- Private ----------------------------------------------------------------

local function handleIncomingReliable(data: any, refs: any?): ()
    local incoming = Reader.decodeIncoming(data)
    if not incoming then
        return
    end

    local incomingLen = buffer.len(incoming)
    local decoded = if _prevIncoming
        then Channel.xorApply(incoming, incomingLen, _prevIncoming, _prevIncomingLen)
        else incoming
    _prevIncoming = decoded
    _prevIncomingLen = incomingLen

    local ok, err = pcall(Reader.process, decoded, incomingLen, refs, nil, false)
    if not ok then
        warn(`[Lync] Client.receive: {err}`)
    end
end

local function handleIncomingUnreliable(data: any, refs: any?): ()
    local incoming = Reader.decodeIncoming(data)
    if not incoming then
        return
    end

    local ok, err = pcall(Reader.process, incoming, buffer.len(incoming), refs, nil, false)
    if not ok then
        warn(`[Lync] Client.receiveUnreliable: {err}`)
    end
end

-- Public -----------------------------------------------------------------

local Client = {}

function Client.getChannel(isUnreliable: boolean): Types.ChannelState
    return if isUnreliable then _unreliable else _reliable
end

function Client.flush(): ()
    if Channel.hasTimestamps() then
        Channel.updateTimestamp()
    end

    if _reliable.cursor > 0 then
        local snapshot, refs, byteLen = Channel.sealAndDump(_reliable)
        local xored = Channel.xorApply(snapshot, byteLen, _reliable.prevDump, _reliable.prevDumpLen)
        _reliable.prevDump = snapshot
        _reliable.prevDumpLen = byteLen
        Bridge.fireServer(xored, refs)
        Channel.reset(_reliable)
    end

    if _unreliable.cursor > 0 then
        local snapshot, refs = Channel.sealAndDump(_unreliable)
        Bridge.fireServerUnreliable(snapshot, refs)
        Channel.reset(_unreliable)
    end
end

function Client.start(): ()
    local container = ReplicatedStorage:WaitForChild(CONTAINER_NAME)
    Bridge.setup(container)

    Bridge.reliable().OnClientEvent:Connect(handleIncomingReliable)
    Bridge.unreliable().OnClientEvent:Connect(handleIncomingUnreliable)
end

return table.freeze(Client)
