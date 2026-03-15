--!strict
--!optimize 2
-- Query.luau — Request-reply over RemoteEvents. No RemoteFunction, no polling.

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
local MAX_PENDING = 256

-- State ------------------------------------------------------------------

local _nextId = 0
local _pending = {} :: { [number]: thread }
local _timeouts = {} :: { [number]: thread }

-- Private ----------------------------------------------------------------

local function allocCorrelation (): number
    local start = _nextId

    repeat
        local id = _nextId
        _nextId = (id + 1) % MAX_PENDING
        if not _pending[id] then
            return id
        end
    until _nextId == start

    error ("[Lync] All 256 query correlation slots are in use")
end

local function resolveCorrelation (id: number, data: any): ()
    local waiting = _pending[id]
    if not waiting then
        return
    end

    _pending[id] = nil

    local timeout = _timeouts[id]
    if timeout then
        task.cancel (timeout)
        _timeouts[id] = nil
    end

    task.spawn (waiting, data)
end

-- Query class
local QueryImpl = {}
QueryImpl.__index = QueryImpl

function QueryImpl.listen (self: any, callback: (...any) -> any): Connection
    if not IS_SERVER then
        error ("[Lync] Query:listen is server-only")
    end

    local respId = self._respReg.id
    local respName = self._name
    local respCodec = self._respReg.codec

    return self._reqReg.signal:connect (
        function (request: any, player: Player, correlation: number): ()
            local response = callback (request, player)
            if response == nil then
                return
            end

            Server.writeQueryResponse (player, respId, respName, correlation, respCodec, response)
        end
    )
end

function QueryImpl.invoke (self: any, request: any): any
    if IS_SERVER then
        error ("[Lync] Query:invoke is client-only")
    end

    local correlation = allocCorrelation ()
    local thread = coroutine.running ()

    _pending[correlation] = thread
    Client.writeQueryRequest (self._reqReg.id, self._name, correlation, self._reqReg.codec, request)

    _timeouts[correlation] = task.delay (self._timeout, function (): ()
        local waiting = _pending[correlation]
        if not waiting then
            return
        end

        _pending[correlation] = nil
        _timeouts[correlation] = nil
        task.spawn (waiting, nil)
    end)

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

    local reqReg, respReg =
        Registry.registerQueryPair (name, config.request, config.response, reqSignal, respSignal)

    if not IS_SERVER then
        respSignal:connect (function (resp: any, correlation: number): ()
            resolveCorrelation (correlation, resp)
        end)
    end

    return setmetatable ({
        _name = name,
        _reqReg = reqReg,
        _respReg = respReg,
        _timeout = config.timeout or 10,
    }, QueryImpl)
end

return table.freeze (Query)
