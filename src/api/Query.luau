--!strict
--!optimize 2
-- Query definition: handle, request with correlation IDs and timeout.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Channel = require(script.Parent.Parent.internal.Channel)
local Log = require(script.Parent.Parent.util.Log)
local Player = require(script.Parent.Parent.util.Player)
local Registry = require(script.Parent.Parent.internal.Registry)
local Transport = require(script.Parent.Parent.internal.Transport)
local Types = require(script.Parent.Parent.Types)

-- Constants --------------------------------------------------------------

local IS_SERVER = RunService:IsServer()
local DEFAULT_TIMEOUT = 5

local EMPTY_OPTIONS: Types.QueryOptions = table.freeze({})

-- State ------------------------------------------------------------------

local _nextCorrId = 0
-- Correlation -> waiting thread / completion closure. Cleared on resolve or timeout.
local _pending: { [number]: thread } = {}
local _pendingGather: { [number]: (any) -> () } = {}

-- Private ----------------------------------------------------------------

local isPlayer = Player.is

local function nextCorr(): number
    _nextCorrId += 1
    return _nextCorrId
end

local function writeQueryTracked(
    ch: Types.ChannelState,
    reg: Types.Registration,
    corrId: number,
    codec: Types.InternalCodec<any>?,
    data: any
): ()
    if Channel.statsEnabled() then
        local before = ch.cursor
        Channel.writeQuery(ch, reg.id, corrId, codec, data, reg.name)
        reg.bytesSent += ch.cursor - before
    else
        Channel.writeQuery(ch, reg.id, corrId, codec, data, reg.name)
    end
end

local function collectTargets(target: any): { Player }
    local targets: { Player } = {}
    if typeof(target) ~= "table" then
        return targets
    end

    local kind = target._lyncKind
    if kind == "all" then
        for _, p in Players:GetPlayers() do
            table.insert(targets, p)
        end
    elseif kind == "group" then
        for p in target._members do
            table.insert(targets, p)
        end
    else
        for _, p in target do
            if isPlayer(p) then
                table.insert(targets, p :: Player)
            end
        end
    end
    return targets
end

-- Public types -----------------------------------------------------------

--[[
    Server `request(data, target)` returns `Resp?` for a Player target and
    `{ [Player]: Resp? }` for a multi-target table; Luau lacks overloads on
    table fields, so the type advertises `Resp?` and multi-target callers cast.
]]
export type QueryHandle<Req, Resp> = {
    handle: (
        self: QueryHandle<Req, Resp>,
        fn: (request: Req, player: Player?) -> Resp?
    ) -> Types.Connection,
    request: (self: QueryHandle<Req, Resp>, data: Req, target: any?) -> Resp?,
    name: (self: QueryHandle<Req, Resp>) -> string,
    stats: (self: QueryHandle<Req, Resp>) -> Types.PacketStats,
}

-- Public -----------------------------------------------------------------

local Query = {}

function Query.define<Req, Resp>(
    name: string,
    requestCodec: Types.InternalCodec<Req>,
    responseCodec: Types.InternalCodec<Resp>,
    options: Types.QueryOptions?
): QueryHandle<Req, Resp>
    local opts = options or EMPTY_OPTIONS
    local timeout = opts.timeout or DEFAULT_TIMEOUT

    local reqOpenFn = Channel.resolveOpenFn(Channel.TS_NONE, name)
    -- Embedded "\0resp" suffix stays uniquely paired with the request reg.
    local respName = `{name}\0resp`
    local respOpenFn = Channel.resolveOpenFn(Channel.TS_NONE, respName)

    local reqReg = Registry.register({
        name = name,
        kind = Registry.KIND_REQUEST,
        codec = requestCodec,
        isUnreliable = false,
        partner = nil,
        needsGate = IS_SERVER,
        headerSize = 1,
        timestampMode = Channel.TS_NONE,
        openFn = reqOpenFn,
        rateLimit = opts.rateLimit or { maxPerSecond = 30 },
        validate = opts.validate,
        maxPayloadBytes = nil,
    })

    local respReg = Registry.register({
        name = respName,
        kind = Registry.KIND_RESPONSE,
        codec = responseCodec,
        isUnreliable = false,
        partner = reqReg.id,
        needsGate = false,
        headerSize = 1,
        timestampMode = Channel.TS_NONE,
        openFn = respOpenFn,
        rateLimit = nil,
        validate = nil,
        maxPayloadBytes = nil,
    })

    reqReg.partner = respReg.id

    -- Single active handler; replacing it disconnects the prior one via handlerToken.
    local activeHandler: ((any, Player?) -> any)? = nil
    local handlerToken = 0

    respReg.signal:connect(function(value: any, _sender: Player?, corrId: number)
        local single = _pending[corrId]
        if single then
            _pending[corrId] = nil
            task.spawn(single, value)
            return
        end
        local gather = _pendingGather[corrId]
        if gather then
            _pendingGather[corrId] = nil
            gather(value)
        end
    end)

    reqReg.signal:connect(function(value: any, sender: Player?, corrId: number)
        local handler = activeHandler
        if not handler then
            return
        end

        local ok, response = pcall(handler, value, sender)
        if not ok then
            Log.warn(`query "{name}" handler errored: {response}`)
        end
        -- pcall failure path returns nil response (writeQuery encodes a nil-MSB header).
        local payloadCodec = if ok then responseCodec else nil
        local payloadData = if ok then response else nil

        local ch: Types.ChannelState? = if IS_SERVER
            then (if sender then Transport.server().getChannel(sender, false) else nil)
            else Transport.client().getChannel(false)
        if ch then
            writeQueryTracked(ch, respReg, corrId, payloadCodec, payloadData)
        end
    end)

    -- Resolve the waiting thread with nil after `timeout` seconds.
    local function scheduleSingleTimeout(corrId: number, running: thread): ()
        task.delay(timeout, function()
            if _pending[corrId] == running then
                _pending[corrId] = nil
                task.spawn(running, nil)
            end
        end)
    end

    -- Issue a single-target query on `ch` and yield until reply or timeout.
    local function requestOnChannel(ch: Types.ChannelState, data: any): any
        local corrId = nextCorr()
        writeQueryTracked(ch, reqReg, corrId, requestCodec, data)

        local running = coroutine.running()
        _pending[corrId] = running
        scheduleSingleTimeout(corrId, running)
        return coroutine.yield()
    end

    local function requestMulti(targets: { Player }, data: any): { [Player]: any }
        local targetCount = #targets
        if targetCount == 0 then
            return {}
        end

        local results: { [Player]: any } = {}
        local remaining = targetCount
        local running = coroutine.running()
        local resolved = false
        local corrIds = table.create(targetCount)

        --[[
            On timeout, surface the partial result table AND evict every
            still-pending closure. Without eviction each unanswered closure
            keeps `results`/`remaining`/`resolveOnce` alive: a slow leak.
        ]]
        local function resolveOnce(): ()
            if resolved then
                return
            end
            resolved = true
            for i = 1, targetCount do
                _pendingGather[corrIds[i]] = nil
            end
            task.spawn(running, results)
        end

        local Server = Transport.server()
        for i, p in targets do
            local pCorr = nextCorr()
            corrIds[i] = pCorr
            local ch = Server.getChannel(p, false)
            writeQueryTracked(ch, reqReg, pCorr, requestCodec, data)

            local pRef = p
            _pendingGather[pCorr] = function(response: any)
                results[pRef] = response
                remaining -= 1
                if remaining == 0 then
                    resolveOnce()
                end
            end
        end

        task.delay(timeout, resolveOnce)
        return coroutine.yield()
    end

    local function requestFromServer(data: any, target: any): any
        if target == nil then
            Log.error(`"{name}" server request requires a target`)
        end
        if isPlayer(target) then
            return requestOnChannel(Transport.server().getChannel(target :: Player, false), data)
        end
        return requestMulti(collectTargets(target), data)
    end

    local function requestFromClient(data: any): any
        return requestOnChannel(Transport.client().getChannel(false), data)
    end

    type Self = QueryHandle<Req, Resp>

    local handle = {
        --[[
            Replace the active handler. The returned Connection only clears
            the active slot if no later :handle has overwritten it: token
            comparison guards against a stale disconnect wiping a fresh handler.
        ]]
        handle = function(
            _self: Self,
            fn: (request: Req, player: Player?) -> Resp?
        ): Types.Connection
            handlerToken += 1
            local myToken = handlerToken
            activeHandler = fn :: any

            local conn: Types.Connection
            conn = {
                connected = true,
                disconnect = function(self): ()
                    if not self.connected then
                        return
                    end
                    self.connected = false
                    if handlerToken == myToken then
                        activeHandler = nil
                    end
                end,
            }
            return conn
        end,

        request = function(_self: Self, data: Req, target: any?): Resp?
            if IS_SERVER then
                return requestFromServer(data, target)
            end
            return requestFromClient(data)
        end,

        name = function(_self: Self): string
            return name
        end,

        stats = function(_self: Self): Types.PacketStats
            return {
                bytesSent = reqReg.bytesSent + respReg.bytesSent,
                bytesReceived = reqReg.bytesReceived + respReg.bytesReceived,
                fires = reqReg.fires + respReg.fires,
                recvFires = reqReg.recvFires + respReg.recvFires,
                drops = reqReg.drops + respReg.drops,
            }
        end,
    }

    return table.freeze(handle) :: QueryHandle<Req, Resp>
end

function Query.pendingCount(): number
    local count = 0
    for _ in _pending do
        count += 1
    end
    for _ in _pendingGather do
        count += 1
    end
    return count
end

return table.freeze(Query)
