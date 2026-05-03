--!strict
--!optimize 2
-- Client transport: single channel pair with outbound XOR delta.

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
local _prevIncomingLen: number = 0

-- Private ----------------------------------------------------------------

local xorApply = Channel.xorApply
local sealAndDump = Channel.sealAndDump
local resetCh = Channel.reset

local function handleIncomingReliable(data: any, refs: any?): ()
    local incoming = Reader.decodeIncoming(data)
    if not incoming then
        return
    end

    local incomingLen = buffer.len(incoming)
    local decoded = xorApply(incoming, incomingLen, _prevIncoming, _prevIncomingLen)

    --[[
        Mirror Server: only adopt `decoded` as the next baseline on success.
        A failed parse means the wire is suspect; reusing it would poison
        every subsequent packet.
    ]]
    if Reader.process(decoded, incomingLen, refs, nil, false) then
        _prevIncoming = decoded
        _prevIncomingLen = incomingLen
    else
        _prevIncoming = nil
        _prevIncomingLen = 0
    end
end

local function handleIncomingUnreliable(data: any, refs: any?): ()
    local incoming = Reader.decodeIncoming(data)
    if not incoming then
        return
    end
    Reader.process(incoming, buffer.len(incoming), refs, nil, false)
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
        local snapshot, refs, byteLen = sealAndDump(_reliable)
        local xored = xorApply(snapshot, byteLen, _reliable.prevDump, _reliable.prevDumpLen)
        _reliable.prevDump = snapshot
        _reliable.prevDumpLen = byteLen
        Bridge.fireServer(xored, refs)
        resetCh(_reliable)
    end

    if _unreliable.cursor > 0 then
        local snapshot, refs = sealAndDump(_unreliable)
        Bridge.fireServerUnreliable(snapshot, refs)
        resetCh(_unreliable)
    end
end

function Client.start(): ()
    local container = ReplicatedStorage:WaitForChild(CONTAINER_NAME)
    Bridge.setup(container)

    Bridge.reliable().OnClientEvent:Connect(handleIncomingReliable)
    Bridge.unreliable().OnClientEvent:Connect(handleIncomingUnreliable)
end

return table.freeze(Client)
