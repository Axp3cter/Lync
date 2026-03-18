--!strict
--!optimize 2
-- Scoped packet/query groups with batch ops and local middleware.

local Middleware = require(script.Parent.Parent.internal.Middleware)
local Packet = require(script.Parent.Packet)
local Query = require(script.Parent.Query)
local Types = require(script.Parent.Parent.Types)

type Connection = Types.Connection
type PacketConfig<T> = Types.PacketConfig<T>
type QueryConfig<R, S> = Types.QueryConfig<R, S>

-- Constants -----------------------------------------------------------

local MAX_NAMESPACES = 64

-- State ---------------------------------------------------------------

local _registered = {} :: { [string]: true }
local _count = 0

-- Private -------------------------------------------------------------

type NamespaceConfig = Types.NamespaceConfig

type NamespaceFields = {
    _name: string,
    _packets: { [string]: Packet.Packet },
    _queries: { [string]: Query.Query },
    _tracked: { Connection },
    _removers: { () -> () },
    packets: { [string]: Packet.Packet },
    queries: { [string]: Query.Query },
}

local function prefixName(nsName: string, name: string): string
    return `{nsName}.{name}`
end

-- Wraps a middleware handler so it only fires for packets in this namespace.
local function scopedHandler(
    nsName: string,
    handler: (data: any, name: string, player: Player?) -> any?
): (data: any, name: string, player: Player?) -> any?
    local prefix = nsName .. "."
    local prefixLen = #prefix

    return function(data: any, name: string, player: Player?): any?
        if string.sub(name, 1, prefixLen) ~= prefix then
            return data
        end
        return handler(data, name, player)
    end
end

local NamespaceImpl = {}
NamespaceImpl.__index = NamespaceImpl

export type Namespace = typeof(setmetatable({} :: NamespaceFields, NamespaceImpl))

-- Listens on every packet in this namespace. Returns a Connection.
function NamespaceImpl.listenAll(
    self: Namespace,
    callback: (name: string, data: any, sender: Player?) -> ()
): Connection
    local connections = {} :: { Connection }
    local prefix = self._name .. "."
    local prefixLen = #prefix

    for fullName, packet in self._packets do
        local shortName = string.sub(fullName, prefixLen + 1)
        local conn = packet:listen(function(data: any, sender: Player?): ()
            callback(shortName, data, sender)
        end)
        table.insert(connections, conn)
        table.insert(self._tracked, conn)
    end

    local bundle: Connection
    bundle = {
        connected = true,
        disconnect = function(self: Connection): ()
            if not self.connected then
                return
            end
            self.connected = false

            for _, inner in connections do
                if inner.connected then
                    inner:disconnect()
                end
            end
        end,
    }

    return bundle
end

-- Disconnects every listenAll connection. Does not remove scoped middleware.
function NamespaceImpl.disconnectAll(self: Namespace): ()
    for _, conn in self._tracked do
        if conn.connected then
            conn:disconnect()
        end
    end
    table.clear(self._tracked)
end

-- Registers send middleware scoped to this namespace. Returns a remover.
function NamespaceImpl.onSend(
    self: Namespace,
    handler: (data: any, name: string, player: Player?) -> any?
): () -> ()
    local wrapped = scopedHandler(self._name, handler)
    local remover = Middleware.addSend(wrapped)
    table.insert(self._removers, remover)

    return function(): ()
        remover()
        local idx = table.find(self._removers, remover)
        if idx then
            table.remove(self._removers, idx)
        end
    end
end

-- Registers receive middleware scoped to this namespace. Returns a remover.
function NamespaceImpl.onReceive(
    self: Namespace,
    handler: (data: any, name: string, player: Player?) -> any?
): () -> ()
    local wrapped = scopedHandler(self._name, handler)
    local remover = Middleware.addReceive(wrapped)
    table.insert(self._removers, remover)

    return function(): ()
        remover()
        local idx = table.find(self._removers, remover)
        if idx then
            table.remove(self._removers, idx)
        end
    end
end

-- Kills all listeners and removes all scoped middleware. Full cleanup.
function NamespaceImpl.destroy(self: Namespace): ()
    self:disconnectAll()

    for _, remover in self._removers do
        remover()
    end
    table.clear(self._removers)
end

-- Returns every packet name(without prefix) in this namespace.
function NamespaceImpl.packetNames(self: Namespace): { string }
    local result = {} :: { string }
    local prefix = self._name .. "."
    local prefixLen = #prefix

    for fullName in self._packets do
        table.insert(result, string.sub(fullName, prefixLen + 1))
    end

    table.sort(result)
    return result
end

-- Returns every query name(without prefix) in this namespace.
function NamespaceImpl.queryNames(self: Namespace): { string }
    local result = {} :: { string }
    local prefix = self._name .. "."
    local prefixLen = #prefix

    for fullName in self._queries do
        table.insert(result, string.sub(fullName, prefixLen + 1))
    end

    table.sort(result)
    return result
end

table.freeze(NamespaceImpl)

-- Public --------------------------------------------------------------

local NamespaceModule = {}

-- Defines a namespace. Names are auto-prefixed to prevent collisions.
function NamespaceModule.define(name: string, config: NamespaceConfig): Namespace
    if #name == 0 then
        error("[Lync] Namespace name must not be empty")
    end
    if _registered[name] then
        error(`[Lync] Duplicate namespace: "{name}"`)
    end
    if _count >= MAX_NAMESPACES then
        error(`[Lync] Namespace limit reached: {MAX_NAMESPACES}`)
    end

    _count += 1
    _registered[name] = true

    local packets = {} :: { [string]: Packet.Packet }
    local queries = {} :: { [string]: Query.Query }
    local packetsByShort = {} :: { [string]: Packet.Packet }
    local queriesByShort = {} :: { [string]: Query.Query }

    if config.packets then
        for shortName, packetConfig in config.packets do
            local fullName = prefixName(name, shortName)
            local packet = Packet.define(fullName, packetConfig)
            packets[fullName] = packet
            packetsByShort[shortName] = packet
        end
    end

    if config.queries then
        for shortName, queryConfig in config.queries do
            local fullName = prefixName(name, shortName)
            local query = Query.define(fullName, queryConfig)
            queries[fullName] = query
            queriesByShort[shortName] = query
        end
    end

    local nsFields: NamespaceFields = {
        _name = name,
        _packets = packets,
        _queries = queries,
        _tracked = {} :: { Connection },
        _removers = {} :: { () -> () },
        packets = table.freeze(packetsByShort),
        queries = table.freeze(queriesByShort),
    }

    -- Inject dynamic short-name accessors (ns.Hit, ns.Stats, etc.)
    -- These bypass the typed fields; consumers should prefer ns.packets.X / ns.queries.X.
    local raw = nsFields :: any
    for shortName, packet in packetsByShort do
        raw[shortName] = packet
    end
    for shortName, query in queriesByShort do
        raw[shortName] = query
    end

    return setmetatable(nsFields, NamespaceImpl)
end

return table.freeze(NamespaceModule)
