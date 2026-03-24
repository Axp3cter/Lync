--!strict
--!optimize 2
-- Client-side transport: single channel pair, flush.

local Types    = require(script.Parent.Parent.Types)
local Channel  = require(script.Parent.Parent.internal.Channel)
local Bridge   = require(script.Parent.Parent.transport.Bridge)
local Reader   = require(script.Parent.Parent.transport.Reader)

-- State ---------------------------------------------------------------

local _reliable: Types.ChannelState = Channel.create()
local _unreliable: Types.ChannelState = Channel.create()
local _prevIncoming: buffer? = nil
local _prevIncomingLen = 0

-- Public --------------------------------------------------------------

local Client = {}

function Client.getChannel(isUnreliable: boolean): Types.ChannelState
    return if isUnreliable then _unreliable else _reliable
end

function Client.flush(): ()
    if Channel.hasTimestamps() then
        Channel.updateTimestamp()
    end

    -- Reliable
    if _reliable.cursor > 0 then
        local snapshot, refs, byteLen, _ = Channel.sealAndDump(_reliable)
        Bridge.fireServer(snapshot, refs)
        Channel.reset(_reliable)
    end

    -- Unreliable
    if _unreliable.cursor > 0 then
        local snapshot, refs, byteLen, _ = Channel.sealAndDump(_unreliable)
        Bridge.fireServerUnreliable(snapshot, refs)
        Channel.reset(_unreliable)
    end
end

function Client.start(): ()
    local container = game:GetService("ReplicatedStorage"):WaitForChild("LyncRemotes")
    Bridge.setup(container)

    local reliable = Bridge.reliable()
    local unreliable = Bridge.unreliable()

    -- Incoming reliable (XOR encoded)
    reliable.OnClientEvent:Connect(function(data: any, refs: any?)
        local incoming = Reader.decodeIncoming(data)
        if not incoming then return end

        local incomingLen = buffer.len(incoming)

        -- XOR decode against previous frame
        local decoded: buffer
        if _prevIncoming then
            decoded = Channel.xorApply(incoming, incomingLen, _prevIncoming, _prevIncomingLen)
        else
            decoded = incoming
        end

        -- Store decoded (not XOR'd) for next frame's XOR base
        _prevIncoming = decoded
        _prevIncomingLen = incomingLen

        local ok, err = pcall(Reader.process, decoded, incomingLen, refs :: any, nil, false)
        if not ok then
            warn(`[Lync] Client: read error: {err}`)
        end
    end)

    -- Incoming unreliable (no XOR)
    unreliable.OnClientEvent:Connect(function(data: any, refs: any?)
        local incoming = Reader.decodeIncoming(data)
        if not incoming then return end

        local incomingLen = buffer.len(incoming)

        local ok, err = pcall(Reader.process, incoming, incomingLen, refs :: any, nil, false)
        if not ok then
            warn(`[Lync] Client: read error (unreliable): {err}`)
        end
    end)
end

return table.freeze(Client)
