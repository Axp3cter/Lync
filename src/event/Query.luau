--!strict
--!optimize 2
-- Bidirectional request-reply over RemoteEvents.

local Players = game:GetService ("Players")
local RunService = game:GetService ("RunService")

local Client = require (script.Parent.Parent.transport.Client)
local Group = require (script.Parent.Parent.event.Group)
local Registry = require (script.Parent.Parent.core.Registry)
local Server = require (script.Parent.Parent.transport.Server)
local Signal = require (script.Parent.Parent.event.Signal)
local Types = require (script.Parent.Parent.Types)

type Connection = Types.Connection
type QueryConfig<R, S> = Types.QueryConfig<R, S>

-- Constants --------------------------------------------------------------

local IS_SERVER = RunService:IsServer ()

-- Wire ceiling: correlationId is u16 in Channel.writeQuery / Reader.process.
local POOL_SIZE = 65536

-- State ------------------------------------------------------------------

type PendingQuery = {
    thread: thread,
    timeout: thread?,
}

local _pending = {} :: { [number]: PendingQuery }
local _nextId = 0
local _activeCount = 0

-- Private ----------------------------------------------------------------

local function allocCorrelation (): number
    if _activeCount >= POOL_SIZE then
        error ("[Lync] All 65536 query correlation slots exhausted")
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

local function freeCorrelation (): ()
    _activeCount -= 1
end

local function completeQuery (id: number, data: any): ()
    local entry = _pending[id]
    if not entry then
        return
    end

    _pending[id] = nil
    freeCorrelation ()

    if entry.timeout then
        task.cancel (entry.timeout)
    end

    coroutine.resume (entry.thread, data)
end

local function onTimeout (correlation: number): ()
    completeQuery (correlation, nil)
end

-- Query class ------------------------------------------------------------

local QueryImpl = {}
QueryImpl.__index = QueryImpl

function QueryImpl.listen (self: any, callback: (...any) -> any): Connection
    local respId = self._respReg.id
    local respName = self._name
    local respCodec = self._respReg.codec

    if IS_SERVER then
        return self._reqReg.signal:connect (
            function (request: any, player: Player, correlation: number): ()
                local ok, response = pcall (callback, request, player)
                if not ok then
                    warn (`[Lync] Query "{respName}" handler error: {response}`)
                end

                if ok and response ~= nil then
                    Server.writeQuery (player, respId, respName, correlation, respCodec, response)
                else
                    Server.writeQueryNil (player, respId, respName, correlation)
                end
            end
        )
    else
        return self._reqReg.signal:connect (
            function (request: any, _player: Player?, correlation: number): ()
                local ok, response = pcall (callback, request)
                if not ok then
                    warn (`[Lync] Query "{respName}" handler error: {response}`)
                end

                if ok and response ~= nil then
                    Client.writeQuery (respId, respName, correlation, respCodec, response)
                else
                    Client.writeQueryNil (respId, respName, correlation)
                end
            end
        )
    end
end

function QueryImpl.invoke (self: any, request: any, player: Player?): any
    if IS_SERVER and not player then
        error ("[Lync] Query:invoke on server requires a player argument")
    end

    local correlation = allocCorrelation ()
    local thread = coroutine.running ()

    local entry: PendingQuery = { thread = thread, timeout = nil }
    _pending[correlation] = entry

    if IS_SERVER then
        Server.writeQuery (
            player :: Player,
            self._reqReg.id,
            self._name,
            correlation,
            self._reqReg.codec,
            request
        )
    else
        Client.writeQuery (self._reqReg.id, self._name, correlation, self._reqReg.codec, request)
    end

    entry.timeout = task.delay (self._timeout, onTimeout, correlation)
    return coroutine.yield ()
end

-- Send a query to multiple players and yield until all respond or time out.
-- Returns { [Player]: response? } where nil means timeout or nil response.
local function invokeMulti (self: any, players: { Player }, request: any): { [Player]: any? }
    if not IS_SERVER then
        error ("[Lync] Multi-invoke is server-only")
    end

    local count = #players
    if count == 0 then
        return {}
    end

    -- Single player: fall through to normal invoke
    if count == 1 then
        local result = QueryImpl.invoke (self, request, players[1])
        return { [players[1]] = result }
    end

    local thread = coroutine.running ()
    local results = {} :: { [Player]: any? }
    local remaining = count
    local correlations = table.create (count) :: { number }
    local finished = false

    local reqId = self._reqReg.id
    local reqName = self._name
    local reqCodec = self._reqReg.codec
    local timeout = self._timeout

    for i = 1, count do
        local player = players[i]
        local correlation = allocCorrelation ()
        correlations[i] = correlation

        -- Each slot gets its own pending entry that resolves into the shared aggregator
        local entry: PendingQuery = {
            thread = coroutine.create (function (data: any): ()
                results[player] = data
                remaining -= 1
                if remaining == 0 and not finished then
                    finished = true
                    task.spawn (thread, results)
                end
            end),
            timeout = nil,
        }

        _pending[correlation] = entry

        Server.writeQuery (player, reqId, reqName, correlation, reqCodec, request)
    end

    -- Shared timeout: cancel everything after the timeout window
    local timeoutThread = task.delay (timeout, function (): ()
        if finished then
            return
        end
        finished = true

        -- Clean up any remaining pending slots
        for i = 1, count do
            local cid = correlations[i]
            local entry = _pending[cid]
            if entry then
                _pending[cid] = nil
                freeCorrelation ()
                if entry.timeout then
                    task.cancel (entry.timeout)
                end
            end
        end

        task.spawn (thread, results)
    end)

    -- Set individual timeouts that feed into the aggregator
    for i = 1, count do
        local cid = correlations[i]
        local entry = _pending[cid]
        if entry then
            entry.timeout = timeoutThread
        end
    end

    return coroutine.yield ()
end

function QueryImpl.invokeAll (self: any, request: any): { [Player]: any? }
    local players = Players:GetPlayers ()
    return invokeMulti (self, players, request)
end

function QueryImpl.invokeList (self: any, request: any, players: { Player }): { [Player]: any? }
    return invokeMulti (self, players, request)
end

function QueryImpl.invokeGroup (self: any, request: any, groupName: string): { [Player]: any? }
    local set = Group.getSet (groupName)
    local players = {} :: { Player }
    for player in set do
        table.insert (players, player)
    end
    return invokeMulti (self, players, request)
end

-- Public -----------------------------------------------------------------

local Query = {}

function Query.define (name: string, config: QueryConfig<any, any>): any
    if not config.request then
        error (`[Lync] Query "{name}" requires a request codec`)
    end
    if not config.response then
        error (`[Lync] Query "{name}" requires a response codec`)
    end

    local reqSignal = Signal.create ()
    local respSignal = Signal.create ()

    local reqReg, respReg = Registry.registerQueryPair (
        name,
        config.request,
        config.response,
        reqSignal,
        respSignal,
        config.rateLimit,
        config.validate
    )

    respSignal:connect (function (resp: any, correlation: number): ()
        completeQuery (correlation, resp)
    end)

    return setmetatable ({
        _name = name,
        _reqReg = reqReg,
        _respReg = respReg,
        _timeout = config.timeout or 5,
    }, QueryImpl)
end

-- Returns the number of queries currently awaiting a response.
function Query.pendingCount (): number
    return _activeCount
end

return table.freeze (Query)
