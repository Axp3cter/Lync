--!strict
--!optimize 2
-- Client.luau — Client-side transport with frame batching.

local RunService = game:GetService("RunService")

local Bridge     = require(script.Parent.Bridge)
local Channel    = require(script.Parent.Parent.core.Channel)
local Compress   = require(script.Parent.Compress)
local Middleware = require(script.Parent.Parent.core.Middleware)
local Reader     = require(script.Parent.Reader)
local Types      = require(script.Parent.Parent.Types)
local Varint     = require(script.Parent.Parent.core.Varint)

type ChannelState = Types.ChannelState
type Codec<T>     = Types.Codec<T>

-- State ------------------------------------------------------------------

local _reliable   = nil :: ChannelState?
local _unreliable = nil :: ChannelState?
local _isStarted  = false

-- Private ----------------------------------------------------------------

local function onReceive(data: any, refs: any, compressed: any): ()
    if typeof(data) ~= "buffer" then return end

    local buf: buffer
    if compressed == true then
        local ok, result = pcall(Compress.unpack, data)
        if not ok then return end
        buf = result
    else
        buf = data
    end

    local safeRefs: { Instance }? = if typeof(refs) == "table" then refs else nil
    local ok, err = pcall(Reader.process, buf, safeRefs, nil, 0)
    if not ok then warn(`[Lync] Client read error: {err}`) end
end

local function flushChannel(remote: any, ch: ChannelState): ()
    if ch.cursor == 0 then return end

    local buf, refs = Channel.dump(ch)
    local packed, wasCompressed = Compress.pack(buf)

    if wasCompressed then
        remote:FireServer(packed, refs, true)
    else
        remote:FireServer(packed, refs)
    end

    Channel.reset(ch)
end

local function flush(): ()
    flushChannel(Bridge.reliable(), _reliable :: ChannelState)
    flushChannel(Bridge.unreliable(), _unreliable :: ChannelState)
end

-- Public -----------------------------------------------------------------

local Client = {}

function Client.start(): ()
    if _isStarted then return end
    _isStarted = true

    Bridge.setup()

    _reliable   = Channel.create()
    _unreliable = Channel.create()

    Bridge.reliable().OnClientEvent:Connect(onReceive)
    Bridge.unreliable().OnClientEvent:Connect(onReceive)
    RunService.Heartbeat:Connect(flush)
end

function Client.write(
    id: number,
    name: string,
    codec: Codec<any>,
    data: any,
    reliability: string
): ()
    local final = Middleware.runSend(data, name, nil)
    if final == nil then return end

    local ch = if reliability == "unreliable"
        then _unreliable :: ChannelState
        else _reliable :: ChannelState

    Varint.write(ch, id)
    codec.write(ch, final)
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
    Varint.write(ch, id)
    Channel.alloc(ch, 1)
    buffer.writeu8(ch.buff, ch.cursor, correlationId)
    ch.cursor += 1
    codec.write(ch, final)
end

return table.freeze(Client)
