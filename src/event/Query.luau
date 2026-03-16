--!strict
--!optimize 2
-- Bidirectional request-reply over RemoteEvents.

local RunService = game:GetService ("RunService")

local Client = require (script.Parent.Parent.transport.Client)
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
                    Server.writeQueryNil (player, respId, correlation)
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
                    Client.writeQueryNil (respId, correlation)
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
