--!strict
--!optimize 2
-- Bidirectional request-reply over RemoteEvents.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Client = require(script.Parent.Parent.transport.Client)
local Registry = require(script.Parent.Parent.internal.Registry)
local Server = require(script.Parent.Parent.transport.Server)
local Signal = require(script.Parent.Signal)
local Types = require(script.Parent.Parent.Types)

type Connection = Types.Connection
type QueryConfig<R, S> = Types.QueryConfig<R, S>
type Registration = Types.Registration

-- Constants -----------------------------------------------------------

local IS_SERVER = RunService:IsServer()

-- Wire ceiling: correlationId is u16 in Channel.writeQuery / Reader.process.
local POOL_SIZE = 65536

-- State ---------------------------------------------------------------

type PendingQuery = {
    thread: thread?,
    callback: ((data: any) -> ())?,
    timeout: thread?,
    source: Player?,
}

local _pending = {} :: { [number]: PendingQuery }
local _nextId = 0
local _activeCount = 0

-- Private -------------------------------------------------------------

local function allocCorrelation(): number
    if _activeCount >= POOL_SIZE then
        error("[Lync] All 65536 query correlation slots exhausted")
    end

    local id = _nextId

    -- Skip occupied slots. With 65536 capacity and typical single-digit
    -- concurrency, this loop body almost never executes.
    while _pending[id] do
        id = (id + 1) % POOL_SIZE
    end

    _nextId = (id + 1) % POOL_SIZE
    _activeCount += 1
    return id
end

-- Decrements the active correlation counter. Does not free a specific slot;
-- that is handled by nil-ing _pending[id] at the call site.
local function releaseCorrelation(): ()
    _activeCount -= 1
end

local function completeQuery(id: number, data: any, source: Player?): ()
    local entry = _pending[id]
    if not entry then
        return
    end

    -- Reject responses from wrong player (prevents correlation spoofing)
    if source ~= nil and entry.source ~= nil and source ~= entry.source then
        return
    end

    _pending[id] = nil
    releaseCorrelation()

    if entry.timeout then
        task.cancel(entry.timeout)
    end

    if entry.callback then
        entry.callback(data)
    elseif entry.thread then
        coroutine.resume(entry.thread :: thread, data)
    end
end

local function onTimeout(correlation: number): ()
    completeQuery(correlation, nil)
end

type QueryFields = {
    _name: string,
    _reqReg: Registration,
    _respReg: Registration,
    _timeout: number,
}

local QueryImpl = {}
QueryImpl.__index = QueryImpl

export type Query = typeof(setmetatable({} :: QueryFields, QueryImpl))

-- Send a query to multiple players and yield. Returns { [Player]: response? }.
local function requestMulti(self: Query, players: { Player }, data: any): { [Player]: any? }
    if not IS_SERVER then
        error("[Lync] Multi-request is server-only")
    end

    local count = #players
    if count == 0 then
        return {}
    end

    if count == 1 then
        local correlation = allocCorrelation()
        local thread = coroutine.running()
        local entry: PendingQuery = { thread = thread, timeout = nil, source = players[1] }
        _pending[correlation] = entry

        Server.writeQuery(
            players[1],
            self._reqReg.id,
            self._name,
            correlation,
            self._reqReg.codec,
            data
        )

        entry.timeout = task.delay(self._timeout, onTimeout, correlation)
        local result = coroutine.yield()
        return { [players[1]] = result }
    end

    local thread = coroutine.running()
    local results = {} :: { [Player]: any? }
    local remaining = count
    local correlations = table.create(count) :: { number }
    local finished = false

    local reqId = self._reqReg.id
    local reqName = self._name
    local reqCodec = self._reqReg.codec
    local timeout = self._timeout

    for i = 1, count do
        local player = players[i]
        local correlation = allocCorrelation()
        correlations[i] = correlation

        local entry: PendingQuery = {
            thread = nil,
            callback = function(resp: any): ()
                results[player] = resp
                remaining -= 1
                if remaining == 0 and not finished then
                    finished = true
                    task.spawn(thread, results)
                end
            end,
            timeout = nil,
            source = player,
        }

        _pending[correlation] = entry
        Server.writeQuery(player, reqId, reqName, correlation, reqCodec, data)
    end

    local timeoutThread = task.delay(timeout, function(): ()
        if finished then
            return
        end
        finished = true

        for i = 1, count do
            local cid = correlations[i]
            if _pending[cid] then
                _pending[cid] = nil
                releaseCorrelation()
            end
        end

        task.spawn(thread, results)
    end)

    for i = 1, count do
        local cid = correlations[i]
        local entry = _pending[cid]
        if entry then
            entry.timeout = timeoutThread
        end
    end

    return coroutine.yield()
end

function QueryImpl.listen(self: Query, callback: (...any) -> any): Connection
    local respId = self._respReg.id
    local respName = self._name
    local respCodec = self._respReg.codec

    if IS_SERVER then
        return self._reqReg.signal:connect(
            function(request: any, player: Player, correlation: number): ()
                local results = table.pack(pcall(callback, request, player))
                if not results[1] then
                    warn(`[Lync] Query handler error on "{respName}": {results[2]}`)
                    Server.writeQueryNil(player, respId, respName, correlation)
                    return
                end

                local response = if results.n > 2
                    then table.move(results, 2, results.n, 1, table.create(results.n - 1))
                    else results[2]

                if response ~= nil then
                    Server.writeQuery(player, respId, respName, correlation, respCodec, response)
                else
                    Server.writeQueryNil(player, respId, respName, correlation)
                end
            end
        )
    else
        return self._reqReg.signal:connect(
            function(request: any, _player: Player?, correlation: number): ()
                local results = table.pack(pcall(callback, request))
                if not results[1] then
                    warn(`[Lync] Query handler error on "{respName}": {results[2]}`)
                    Client.writeQueryNil(respId, respName, correlation)
                    return
                end

                local response = if results.n > 2
                    then table.move(results, 2, results.n, 1, table.create(results.n - 1))
                    else results[2]

                if response ~= nil then
                    Client.writeQuery(respId, respName, correlation, respCodec, response)
                else
                    Client.writeQueryNil(respId, respName, correlation)
                end
            end
        )
    end
end

-- Client: send request to server, yield until response.
function QueryImpl.request(self: Query, data: any): any
    if IS_SERVER then
        error("[Lync] query:request is client-only. Use query:requestFrom on server")
    end

    local correlation = allocCorrelation()
    local thread = coroutine.running()
    local entry: PendingQuery = { thread = thread, timeout = nil }
    _pending[correlation] = entry

    Client.writeQuery(self._reqReg.id, self._name, correlation, self._reqReg.codec, data)

    entry.timeout = task.delay(self._timeout, onTimeout, correlation)
    return coroutine.yield()
end

-- Server: send request to one player, yield until response.
function QueryImpl.requestFrom(self: Query, player: Player, data: any): any
    if not IS_SERVER then
        error("[Lync] query:requestFrom is server-only. Use query:request on client")
    end

    local correlation = allocCorrelation()
    local thread = coroutine.running()
    local entry: PendingQuery = { thread = thread, timeout = nil, source = player }
    _pending[correlation] = entry

    Server.writeQuery(player, self._reqReg.id, self._name, correlation, self._reqReg.codec, data)

    entry.timeout = task.delay(self._timeout, onTimeout, correlation)
    return coroutine.yield()
end

-- Server: send request to all players, yield until all respond or timeout.
function QueryImpl.requestAll(self: Query, data: any): { [Player]: any? }
    return requestMulti(self, Players:GetPlayers(), data)
end

-- Server: send request to a list of players.
function QueryImpl.requestList(self: Query, players: { Player }, data: any): { [Player]: any? }
    return requestMulti(self, players, data)
end

-- Server: send request to all players in a group.
function QueryImpl.requestGroup(self: Query, group: any, data: any): { [Player]: any? }
    local set = group:getSet()
    local players = {} :: { Player }
    for player in set do
        table.insert(players, player)
    end
    return requestMulti(self, players, data)
end

table.freeze(QueryImpl)

-- Public --------------------------------------------------------------

local QueryModule = {}

function QueryModule.define(name: string, config: QueryConfig<any, any>): Query
    if not config.request then
        error(`[Lync] Query requires a request codec: "{name}"`)
    end
    if not config.response then
        error(`[Lync] Query requires a response codec: "{name}"`)
    end

    local reqSignal = Signal.create()
    local respSignal = Signal.create()

    local rateLimit = config.rateLimit or { maxPerSecond = 30 }

    local Channel = require(script.Parent.Parent.internal.Channel)

    local reqReg, respReg = Registry.registerQueryPair(
        name,
        config.request,
        config.response,
        reqSignal,
        respSignal,
        rateLimit,
        config.validate
    )

    -- Queries use writeQuery, not writeBatch, but _openFn must be set
    local openFn = Channel.resolveOpenFn(0)
    reqReg._openFn = openFn
    respReg._openFn = openFn

    respSignal:connect(function(resp: any, source: Player?, correlation: number): ()
        completeQuery(correlation, resp, source)
    end)

    return setmetatable({
        _name = name,
        _reqReg = reqReg,
        _respReg = respReg,
        _timeout = config.timeout or 5,
    }, QueryImpl)
end

-- Returns the number of queries currently awaiting a response.
function QueryModule.pendingCount(): number
    return _activeCount
end

return table.freeze(QueryModule)
