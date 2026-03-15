--!strict
--!optimize 2
-- Client.luau — Client-side transport with batching, frame XOR on reliable.

local RunService = game:GetService("RunService")

local Bridge     = require(script.Parent.Bridge)
local Channel    = require(script.Parent.Parent.core.Channel)
local Compress   = require(script.Parent.Compress)
local Middleware = require(script.Parent.Parent.core.Middleware)
local Reader     = require(script.Parent.Reader)
local Types      = require(script.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T>     = Types.Codec<T>

-- Constants --------------------------------------------------------------

local MAX_INCOMING = 65536

-- State ------------------------------------------------------------------

local _reliable   = nil :: ChannelState?
local _unreliable = nil :: ChannelState?
local _prevRecv   = nil :: buffer?
local _isStarted  = false

-- Private ----------------------------------------------------------------

local function decodeIncoming(data: any, compressed: any): buffer?
    if typeof(data) ~= "buffer" then return nil end
    if buffer.len(data) > MAX_INCOMING then return nil end

    if compressed == true then
        local ok, result = pcall(Compress.unpack, data)
        if not ok then return nil end
        return result
    end

    return data
end

local function receive(data: any, refs: any, compressed: any, applyXor: boolean): ()
    local buf = decodeIncoming(data, compressed)
    if not buf then return end

    local raw: buffer
    if applyXor then
        raw = Channel.xorApply(buf, _prevRecv)
        _prevRecv = raw
    else
        raw = buf
    end

    local safeRefs: { Instance }? = if typeof(refs) == "table" then refs else nil
    local ok, err = pcall(Reader.process, raw, safeRefs, nil, 0)
    if not ok then warn(`[Lync] Client read error: {err}`) end
end

local function flushChannel(remote: any, ch: ChannelState, applyXor: boolean): ()
    if ch.cursor == 0 then return end

    Channel.seal(ch)

    local raw, refs = Channel.dump(ch)
    local payload: buffer

    if applyXor then
        local xored = Channel.xorApply(raw, ch.prevDump)
        ch.prevDump = raw
        payload = xored
    else
        payload = raw
    end

    local packed, wasCompressed = Compress.pack(payload)

    if wasCompressed then
        remote:FireServer(packed, refs, true)
    else
        remote:FireServer(packed, refs)
    end

    Channel.reset(ch)
end

local function flush(): ()
    flushChannel(Bridge.reliable(), _reliable :: ChannelState, true)
    flushChannel(Bridge.unreliable(), _unreliable :: ChannelState, false)
end

-- Public -----------------------------------------------------------------

local Client = {}

function Client.start(): ()
    if _isStarted then return end
    _isStarted = true

    Bridge.setup()

    _reliable   = Channel.create()
    _unreliable = Channel.create()

    Bridge.reliable().OnClientEvent:Connect(function(data: any, refs: any, compressed: any): ()
        receive(data, refs, compressed, true)
    end)
    Bridge.unreliable().OnClientEvent:Connect(function(data: any, refs: any, compressed: any): ()
        receive(data, refs, compressed, false)
    end)
    RunService.Heartbeat:Connect(flush)
end

function Client.write(
    id: number,
    name: string,
    codec: Codec<any>,
    data: any,
    isUnreliable: boolean
): ()
    local final = Middleware.runSend(data, name, nil)
    if final == nil then return end

    local ch = if isUnreliable
        then _unreliable :: ChannelState
        else _reliable :: ChannelState

    Channel.writeBatch(ch, id, codec, final)
end

function Client.writeQueryRequest(
    id: number,
    name: string,
    correlationId: number,
    codec: Codec<any>,
    data: any
): ()
    local final = Middleware.runSend(data, name, nil)
    if final == nil then return end

    local ch = _reliable :: ChannelState
    Channel.seal(ch)
    Channel.alloc(ch, 2)
    buffer.writeu8(ch.buff, ch.cursor, id)
    buffer.writeu8(ch.buff, ch.cursor + 1, correlationId)
    ch.cursor += 2
    codec.write(ch, final)
    ch.lastId = -1
end

return table.freeze(Client)
