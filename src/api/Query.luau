--!strict
--!optimize 2
-- Query definition: handle, request with correlation IDs and timeout.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Baseline = require(script.Parent.Parent.internal.Baseline)
local Channel = require(script.Parent.Parent.internal.Channel)
local Registry = require(script.Parent.Parent.internal.Registry)
local Types = require(script.Parent.Parent.Types)

-- Constants -----------------------------------------------------------

local IS_SERVER = RunService:IsServer()
local DEFAULT_TIMEOUT = 5

-- State ---------------------------------------------------------------

local _nextCorrId = 0
local _pending: { [number]: thread } = {}

-- Public --------------------------------------------------------------

local Query = {}

export type QueryHandle = {
    handle: (self: QueryHandle, fn: (request: any, player: Player?) -> any) -> Types.Connection,
    request: (self: QueryHandle, data: any, target: any?) -> any,
    name: (self: QueryHandle) -> string,
    stats: (self: QueryHandle) -> Types.PacketStats,
}

function Query.define(
    name: string,
    requestCodec: Types.InternalCodec<any>,
    responseCodec: Types.InternalCodec<any>,
    options: Types.QueryOptions?
): QueryHandle
    local opts = options or {} :: Types.QueryOptions
    local timeout = opts.timeout or DEFAULT_TIMEOUT

    -- Register request channel
    local reqOpenFn = Channel.resolveOpenFn(Channel.TS_NONE, name)
    local reqReg = Registry.register(
        name,
        Registry.KIND_REQUEST,
        requestCodec,
        false,
        nil,
        IS_SERVER,
        1,
        Channel.TS_NONE,
        reqOpenFn,
        opts.rateLimit or { maxPerSecond = 30 },
        opts.validate,
        nil
    )

    -- Register response channel (paired)
    local respOpenFn = Channel.resolveOpenFn(Channel.TS_NONE, `{name}_resp`)
    local respReg = Registry.register(
        `{name}_resp`,
        Registry.KIND_RESPONSE,
        responseCodec,
        false,
        reqReg.id,
        false,
        1,
        Channel.TS_NONE,
        respOpenFn,
        nil,
        nil,
        nil
    )

    reqReg.partner = respReg.id

    -- Lazy-require to avoid circular deps
    local _server: any = nil
    local _client: any = nil

    local function getServer(): any
        if not _server then
            _server = require(script.Parent.Parent.transport.Server)
        end
        return _server
    end

    local function getClient(): any
        if not _client then
            _client = require(script.Parent.Parent.transport.Client)
        end
        return _client
    end

    -- Listen for incoming responses and resolve pending requests
    respReg.signal:connect(function(value: any, sender: Player?, corrId: number)
        local waiting = _pending[corrId]
        if waiting then
            _pending[corrId] = nil
            task.spawn(waiting, value)
        end
    end)

    -- Listen for incoming requests and auto-respond
    local _handler: ((any, Player?) -> any)? = nil

    reqReg.signal:connect(function(value: any, sender: Player?, corrId: number)
        if not _handler then
            return
        end

        -- Run handler, get response
        local ok, response = pcall(_handler :: any, value, sender)

        if IS_SERVER then
            if sender then
                local Server = getServer()
                local ch = Server.getChannel(sender, false)
                if ok then
                    Channel.writeQuery(ch, respReg.id, corrId, responseCodec, response)
                else
                    Channel.writeQuery(ch, respReg.id, corrId, nil, nil)
                end
            end
        else
            local Client = getClient()
            local ch = Client.getChannel(false)
            if ok then
                Channel.writeQuery(ch, respReg.id, corrId, responseCodec, response)
            else
                Channel.writeQuery(ch, respReg.id, corrId, nil, nil)
            end
        end
    end)

    local handle: any = {}

    function handle.handle(
        _self: QueryHandle,
        fn: (request: any, player: Player?) -> any
    ): Types.Connection
        _handler = fn

        -- Return a connection that clears the handler on disconnect
        return table.freeze({
            connected = true,
            disconnect = function(self: Types.Connection): ()
                if not (self :: any).connected then
                    return
                end
                (self :: any).connected = false
                _handler = nil
            end,
        } :: any)
    end

    function handle.request(_self: QueryHandle, data: any, target: any?): any
        _nextCorrId += 1
        local corrId = _nextCorrId

        if IS_SERVER then
            if target == nil then
                error(`[Lync] Query "{name}": server request requires a target`)
            end

            local Server = getServer()

            -- Single player
            if typeof(target) == "Instance" and target:IsA("Player") then
                local ch = Server.getChannel(target :: Player, false)
                Channel.writeQuery(ch, reqReg.id, corrId, requestCodec, data)

                -- Wait for response
                local running = coroutine.running()
                _pending[corrId] = running

                task.delay(timeout, function()
                    if _pending[corrId] == running then
                        _pending[corrId] = nil
                        task.spawn(running, nil)
                    end
                end)

                return coroutine.yield()
            end

            -- Multi-target: collect responses into { [Player]: response? }
            local targets: { Player } = {}

            if typeof(target) == "table" then
                local tbl = target :: any
                if tbl._lyncAll then
                    targets = Players:GetPlayers()
                elseif tbl._lyncGroup then
                    for player in tbl._members do
                        table.insert(targets, player)
                    end
                else
                    for _, p in tbl do
                        if typeof(p) == "Instance" and (p :: Instance):IsA("Player") then
                            table.insert(targets, p :: Player)
                        end
                    end
                end
            end

            if #targets == 0 then
                return {}
            end

            local results: { [Player]: any } = {}
            local remaining = #targets
            local running = coroutine.running()

            for _, player in targets do
                _nextCorrId += 1
                local playerCorrId = _nextCorrId
                local ch = Server.getChannel(player, false)
                Channel.writeQuery(ch, reqReg.id, playerCorrId, requestCodec, data)

                local playerRef = player
                _pending[playerCorrId] = coroutine.create(function(response: any)
                    results[playerRef] = response
                    remaining -= 1
                    if remaining == 0 then
                        task.spawn(running, results)
                    end
                end)
            end

            -- Timeout
            task.delay(timeout, function()
                if remaining > 0 then
                    remaining = 0
                    task.spawn(running, results)
                end
            end)

            return coroutine.yield()
        else
            -- Client → server
            local Client = getClient()
            local ch = Client.getChannel(false)
            Channel.writeQuery(ch, reqReg.id, corrId, requestCodec, data)

            local running = coroutine.running()
            _pending[corrId] = running

            task.delay(timeout, function()
                if _pending[corrId] == running then
                    _pending[corrId] = nil
                    task.spawn(running, nil)
                end
            end)

            return coroutine.yield()
        end
    end

    function handle.name(_self: QueryHandle): string
        return name
    end

    function handle.stats(_self: QueryHandle): Types.PacketStats
        return {
            bytesSent = reqReg.bytesSent + respReg.bytesSent,
            bytesReceived = reqReg.bytesReceived + respReg.bytesReceived,
            fires = reqReg.fires + respReg.fires,
            recvFires = reqReg.recvFires + respReg.recvFires,
            drops = reqReg.drops + respReg.drops,
        }
    end

    return table.freeze(handle)
end

function Query.pendingCount(): number
    local count = 0
    for _ in _pending do
        count += 1
    end
    return count
end

return table.freeze(Query)
