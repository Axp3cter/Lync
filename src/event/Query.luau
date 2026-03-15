--!strict
--!optimize 2
-- Request-reply over RemoteEvents.

local RunService = game:GetService("RunService")

local Registry = require(script.Parent.Parent.core.Registry)
local Signal   = require(script.Parent.Parent.event.Signal)
local Server   = require(script.Parent.Parent.transport.Server)
local Client   = require(script.Parent.Parent.transport.Client)
local Types    = require(script.Parent.Parent.Types)

type Connection        = Types.Connection
type QueryConfig<R, S> = Types.QueryConfig<R, S>

-- Constants --------------------------------------------------------------

local IS_SERVER = RunService:IsServer()

-- Correlation IDs are u8 on the wire. This ceiling MUST NOT exceed 256.
local MAX_PENDING = 256

-- State ------------------------------------------------------------------

local _pending  = {} :: { [number]: thread }
local _timeouts = {} :: { [number]: thread }

-- Free-stack for O(1) correlation ID allocation
local _freeStack = table.create(MAX_PENDING) :: { number }
local _freeDepth = MAX_PENDING

-- Private ----------------------------------------------------------------

-- Pre-fill the free stack with all IDs
for i = 0, MAX_PENDING - 1 do
    _freeStack[i + 1] = i
end

local function allocCorrelation(): number
    if _freeDepth == 0 then
        error(`[Lync] All {MAX_PENDING} query correlation slots are in use`)
    end

    local id = _freeStack[_freeDepth]
    _freeStack[_freeDepth] = nil :: any
    _freeDepth -= 1
    return id
end

local function freeCorrelation(id: number): ()
    _freeDepth += 1
    _freeStack[_freeDepth] = id
end

local function resolveCorrelation(id: number, data: any): ()
    local waiting = _pending[id]
    if not waiting then return end

    _pending[id] = nil
    freeCorrelation(id)

    local timeout = _timeouts[id]
    if timeout then
        task.cancel(timeout)
        _timeouts[id] = nil
    end

    coroutine.resume(waiting, data)
end

-- Shared timeout handler — avoids NEWCLOSURE per invoke.
-- Reads correlation ID from the thread's first argument.
local function onTimeout(correlation: number): ()
    local waiting = _pending[correlation]
    if not waiting then return end

    _pending[correlation]  = nil
    _timeouts[correlation] = nil
    freeCorrelation(correlation)

    coroutine.resume(waiting, nil)
end

-- Query class
local QueryImpl = {}
QueryImpl.__index = QueryImpl

function QueryImpl.listen(self: any, callback: (...any) -> any): Connection
    if not IS_SERVER then error("[Lync] Query:listen is server-only") end

    local respId    = self._respReg.id
    local respName  = self._name
    local respCodec = self._respReg.codec

    return self._reqReg.signal:connect(function(request: any, player: Player, correlation: number): ()
        local ok, response = pcall(callback, request, player)
        if not ok then
            warn(`[Lync] Query "{respName}" handler error: {response}`)
            return
        end
        if response == nil then return end

        Server.writeQueryResponse(player, respId, respName, correlation, respCodec, response)
    end)
end

function QueryImpl.invoke(self: any, request: any): any
    if IS_SERVER then error("[Lync] Query:invoke is client-only") end

    local correlation = allocCorrelation()
    local thread      = coroutine.running()

    _pending[correlation] = thread
    Client.writeQueryRequest(
        self._reqReg.id, self._name, correlation, self._reqReg.codec, request
    )

    _timeouts[correlation] = task.delay(self._timeout, onTimeout, correlation)

    return coroutine.yield()
end

-- Public -----------------------------------------------------------------

local Query = {}

function Query.define(name: string, config: QueryConfig<any, any>): any
    if not config.request then error(`[Lync] Query "{name}" requires a request codec`) end
    if not config.response then error(`[Lync] Query "{name}" requires a response codec`) end

    local reqSignal  = Signal.create()
    local respSignal = Signal.create()

    local reqReg, respReg = Registry.registerQueryPair(
        name, config.request, config.response, reqSignal, respSignal
    )

    if not IS_SERVER then
        respSignal:connect(function(resp: any, correlation: number): ()
            resolveCorrelation(correlation, resp)
        end)
    end

    return setmetatable({
        _name    = name,
        _reqReg  = reqReg,
        _respReg = respReg,
        _timeout = config.timeout or 5,
    }, QueryImpl)
end

return table.freeze(Query)
