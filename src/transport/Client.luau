--!strict
--!optimize 2
-- Client-side transport with batching, frame XOR on reliable.

local RunService = game:GetService("RunService")

local Bridge = require(script.Parent.Bridge)
local Channel = require(script.Parent.Parent.internal.Channel)
local Middleware = require(script.Parent.Parent.internal.Middleware)
local Reader = require(script.Parent.Reader)
local Types = require(script.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T> = Types.Codec<T>
type Registration = Types.Registration

-- State ---------------------------------------------------------------

local NOT_STARTED = "[Lync] Client not started. Call Lync.start() before sending"

local _reliable = nil :: ChannelState?
local _unreliable = nil :: ChannelState?
local _prevRecv = nil :: buffer?
local _isStarted = false

-- Flush control
local _flushRate = 60
local _flushAccum = 0
local _flushInterval = 1 / 60

-- Timestamp
local _frameCounter: number = 0

-- Private -------------------------------------------------------------

local function receive(data: any, refs: any, applyXor: boolean): ()
    local buf = Reader.decodeIncoming(data)
    if not buf then
        return
    end

    local raw: buffer
    if applyXor then
        raw = Channel.xorApply(buf, _prevRecv)
        _prevRecv = raw
    else
        raw = buf
    end

    local safeRefs: { Instance }? = if typeof(refs) == "table" then refs else nil
    local ok, err = pcall(Reader.process, raw, safeRefs, nil, 0)
    if not ok then
        warn(`[Lync] Read failed: {err}`)
    end
end

local function flushChannel(remote: any, ch: ChannelState, applyXor: boolean): ()
    if ch.cursor == 0 then
        return
    end

    local raw, refs = Channel.sealAndDump(ch)

    if applyXor then
        local xored = Channel.xorApply(raw, ch.prevDump)
        ch.prevDump = raw
        remote:FireServer(xored, refs)
    else
        remote:FireServer(raw, refs)
    end

    Channel.reset(ch)
end

local function flush(): ()
    _frameCounter = (_frameCounter + 1) % 256
    local now = os.clock()
    Channel.updateTimestamp(_frameCounter, 0, now)

    flushChannel(Bridge.reliable, _reliable :: ChannelState, true)
    flushChannel(Bridge.unreliable, _unreliable :: ChannelState, false)
end

-- Public --------------------------------------------------------------

local Client = {}

function Client.start(): ()
    if _isStarted then
        return
    end
    _isStarted = true

    Bridge.setup()

    _reliable = Channel.create()
    _unreliable = Channel.create()

    Bridge.reliable.OnClientEvent:Connect(function(data: any, refs: any): ()
        receive(data, refs, true)
    end)
    Bridge.unreliable.OnClientEvent:Connect(function(data: any, refs: any): ()
        receive(data, refs, false)
    end)
    RunService.Heartbeat:Connect(function(dt: number)
        _flushAccum += dt
        if _flushAccum < _flushInterval then
            return
        end
        _flushAccum = 0
        flush()
    end)
end

function Client.write(reg: Registration, data: any, isUnreliable: boolean): ()
    if not _isStarted then
        error(NOT_STARTED)
    end

    local final: any
    if Middleware.hasSend then
        final = Middleware.runSend(data, reg.name, nil)
        if final == nil then
            return
        end
    else
        final = data
    end

    local ch = if isUnreliable then _unreliable :: ChannelState else _reliable :: ChannelState
    local before = ch.cursor
    Channel.writeBatch(ch, reg, final)
    reg.bytesSent += ch.cursor - before
    reg.fires += 1
end

-- Shared for both query requests and responses (identical wire format).
function Client.writeQuery(
    id: number,
    name: string,
    correlationId: number,
    codec: Codec<any>,
    data: any
): ()
    if not _isStarted then
        error(NOT_STARTED)
    end

    local final: any
    if Middleware.hasSend then
        final = Middleware.runSend(data, name, nil)
        if final == nil then
            return
        end
    else
        final = data
    end

    Channel.writeQuery(_reliable :: ChannelState, id, name, correlationId, codec, final)
end

function Client.writeQueryNil(id: number, name: string, correlationId: number): ()
    if not _isStarted then
        error(NOT_STARTED)
    end
    Channel.writeQuery(_reliable :: ChannelState, id, name, correlationId, nil, nil)
end

function Client.flush(): ()
    _flushAccum = 0
    flush()
end

function Client.setFlushRate(hz: number): ()
    _flushRate = math.clamp(hz, 1, 60)
    _flushInterval = 1 / _flushRate
end

function Client.getFlushRate(): number
    return _flushRate
end

return table.freeze(Client)
