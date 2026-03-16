--!strict
--!optimize 2
-- Client-side transport with batching, frame XOR on reliable.

local RunService = game:GetService ("RunService")

local Bridge     = require (script.Parent.Bridge)
local Channel    = require (script.Parent.Parent.core.Channel)
local Middleware = require (script.Parent.Parent.core.Middleware)
local Reader     = require (script.Parent.Reader)
local Types      = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T>     = Types.Codec<T>

-- State ------------------------------------------------------------------

local _reliable   = nil :: ChannelState?
local _unreliable = nil :: ChannelState?
local _prevRecv   = nil :: buffer?
local _isStarted  = false

-- Private ----------------------------------------------------------------

local function assertStarted (): ()
    if not _isStarted then
        error ("[Lync] Client not started — call Lync.start() before sending")
    end
end

local function receive (data: any, refs: any, applyXor: boolean): ()
    local buf = Reader.decodeIncoming (data)
    if not buf then
        return
    end

    local raw: buffer
    if applyXor then
        raw = Channel.xorApply (buf, _prevRecv)
        _prevRecv = raw
    else
        raw = buf
    end

    local safeRefs: { Instance }? = if typeof (refs) == "table" then refs else nil
    local ok, err = pcall (Reader.process, raw, safeRefs, nil, 0)
    if not ok then
        warn (`[Lync] Read failed: {err}`)
    end
end

local function flushChannel (remote: any, ch: ChannelState, applyXor: boolean): ()
    if ch.cursor == 0 then
        return
    end

    local raw, refs = Channel.sealAndDump (ch)

    if applyXor then
        local xored = Channel.xorApply (raw, ch.prevDump)
        ch.prevDump = raw
        remote:FireServer (xored, refs)
    else
        remote:FireServer (raw, refs)
    end

    Channel.reset (ch)
end

local function flush (): ()
    flushChannel (Bridge.reliable, _reliable :: ChannelState, true)
    flushChannel (Bridge.unreliable, _unreliable :: ChannelState, false)
end

-- Public -----------------------------------------------------------------

local Client = {}

function Client.start (): ()
    if _isStarted then
        return
    end
    _isStarted = true

    Bridge.setup ()

    _reliable = Channel.create ()
    _unreliable = Channel.create ()

    Bridge.reliable.OnClientEvent:Connect (function (data: any, refs: any): ()
        receive (data, refs, true)
    end)
    Bridge.unreliable.OnClientEvent:Connect (function (data: any, refs: any): ()
        receive (data, refs, false)
    end)
    RunService.Heartbeat:Connect (flush)
end

function Client.write (
    id: number,
    name: string,
    codec: Codec<any>,
    data: any,
    isUnreliable: boolean
): ()
    assertStarted ()

    local final = Middleware.runSend (data, name, nil)
    if final == nil then
        return
    end

    local ch = if isUnreliable then _unreliable :: ChannelState else _reliable :: ChannelState
    Channel.writeBatch (ch, id, codec, final)
end

-- Shared for both query requests and responses (identical wire format).
function Client.writeQuery (
    id: number,
    name: string,
    correlationId: number,
    codec: Codec<any>,
    data: any
): ()
    assertStarted ()

    local final = Middleware.runSend (data, name, nil)
    if final == nil then
        return
    end

    Channel.writeQuery (_reliable :: ChannelState, id, correlationId, codec, final)
end

function Client.writeQueryNil (id: number, correlationId: number): ()
    assertStarted ()
    Channel.writeQuery (_reliable :: ChannelState, id, correlationId, nil, nil)
end

return table.freeze (Client)
