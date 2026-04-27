--!strict
--!optimize 2
-- Query definition: handle, request with correlation IDs and timeout.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Channel = require(script.Parent.Parent.internal.Channel)
local Registry = require(script.Parent.Parent.internal.Registry)
local Transport = require(script.Parent.Parent.internal.Transport)
local Types = require(script.Parent.Parent.Types)
local Util = require(script.Parent.Parent.internal.Util)

-- Constants --------------------------------------------------------------

local IS_SERVER = RunService:IsServer()
local DEFAULT_TIMEOUT = 5

-- State ------------------------------------------------------------------

local _nextCorrId = 0
local _pending: { [number]: thread } = {}
local _pendingGather: { [number]: (any) -> () } = {}

-- Private ----------------------------------------------------------------

local isPlayer = Util.isPlayer

local function nextCorr(): number
    _nextCorrId += 1
    return _nextCorrId
end

-- Public types -----------------------------------------------------------

export type QueryHandle = {
    handle: (self: QueryHandle, fn: (request: any, player: Player?) -> any) -> Types.Connection,
    request: (self: QueryHandle, data: any, target: any?) -> any,
    name: (self: QueryHandle) -> string,
    stats: (self: QueryHandle) -> Types.PacketStats,
}

-- Public -----------------------------------------------------------------

local Query = {}

function Query.define(
    name: string,
    requestCodec: Types.InternalCodec<any>,
    responseCodec: Types.InternalCodec<any>,
    options: Types.QueryOptions?
): QueryHandle
    local opts = options or ({} :: Types.QueryOptions)
    local timeout = opts.timeout or DEFAULT_TIMEOUT

    local reqOpenFn = Channel.resolveOpenFn(Channel.TS_NONE, name)
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
        local payloadCodec = if ok then responseCodec else nil
        local payloadData = if ok then response else nil

        local ch = if IS_SERVER and sender
            then Transport.server().getChannel(sender, false)
            elseif not IS_SERVER then Transport.client().getChannel(false)
            else nil
        if ch then
            Channel.writeQuery(ch, respReg.id, corrId, payloadCodec, payloadData)
        end
    end)

    local function scheduleSingleTimeout(corrId: number, running: thread): ()
        task.delay(timeout, function()
            if _pending[corrId] == running then
                _pending[corrId] = nil
                task.spawn(running, nil)
            end
        end)
    end

    local function requestSingle(target: Player, data: any): any
        local corrId = nextCorr()
        local ch = Transport.server().getChannel(target, false)
        Channel.writeQuery(ch, reqReg.id, corrId, requestCodec, data)

        local running = coroutine.running()
        _pending[corrId] = running
        scheduleSingleTimeout(corrId, running)
        return coroutine.yield()
    end

    local function requestMulti(targets: { Player }, data: any): { [Player]: any }
        if #targets == 0 then
            return {}
        end

        local results: { [Player]: any } = {}
        local remaining = #targets
        local running = coroutine.running()
        local resolved = false

        local function resolveOnce(): ()
            if resolved then
                return
            end
            resolved = true
            task.spawn(running, results)
        end

        local Server = Transport.server()
        for _, player in targets do
            local pCorr = nextCorr()
            local ch = Server.getChannel(player, false)
            Channel.writeQuery(ch, reqReg.id, pCorr, requestCodec, data)

            local pRef = player
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

    local function collectTargets(target: any): { Player }
        local targets: { Player } = {}
        if typeof(target) ~= "table" then
            return targets
        end

        if target._lyncAll then
            for _, p in Players:GetPlayers() do
                table.insert(targets, p)
            end
        elseif target._lyncGroup then
            for player in target._members do
                table.insert(targets, player)
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

    local function requestFromServer(data: any, target: any): any
        if target == nil then
            error(`[Lync] Query.request: "{name}" server request requires a target`)
        end
        if isPlayer(target) then
            return requestSingle(target :: Player, data)
        end
        return requestMulti(collectTargets(target), data)
    end

    local function requestFromClient(data: any): any
        local corrId = nextCorr()
        local ch = Transport.client().getChannel(false)
        Channel.writeQuery(ch, reqReg.id, corrId, requestCodec, data)

        local running = coroutine.running()
        _pending[corrId] = running
        scheduleSingleTimeout(corrId, running)
        return coroutine.yield()
    end

    local handle = {
        handle = function(
            _self: QueryHandle,
            fn: (request: any, player: Player?) -> any
        ): Types.Connection
            handlerToken += 1
            local myToken = handlerToken
            activeHandler = fn

            local conn = { connected = true }
            function conn.disconnect(self): ()
                if not self.connected then
                    return
                end
                self.connected = false
                if handlerToken == myToken then
                    activeHandler = nil
                end
            end
            return conn :: Types.Connection
        end,

        request = function(_self: QueryHandle, data: any, target: any?): any
            if IS_SERVER then
                return requestFromServer(data, target)
            end
            return requestFromClient(data)
        end,

        name = function(_self: QueryHandle): string
            return name
        end,

        stats = function(_self: QueryHandle): Types.PacketStats
            return {
                bytesSent = reqReg.bytesSent + respReg.bytesSent,
                bytesReceived = reqReg.bytesReceived + respReg.bytesReceived,
                fires = reqReg.fires + respReg.fires,
                recvFires = reqReg.recvFires + respReg.recvFires,
                drops = reqReg.drops + respReg.drops,
            }
        end,
    }

    return table.freeze(handle) :: QueryHandle
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
