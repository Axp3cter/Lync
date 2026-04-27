--!strict
--!optimize 2
-- Batched connection lifecycle. Accepts Lync Connection,
-- RBXScriptConnection, and any object with :disconnect() / :Disconnect().

local Types = require(script.Parent.Parent.Types)

-- Public types -----------------------------------------------------------

export type ScopeHandle = {
    on: (self: ScopeHandle, source: any, fn: (...any) -> ()) -> Types.Connection,
    once: (self: ScopeHandle, source: any, fn: (...any) -> ()) -> Types.Connection,
    add: (self: ScopeHandle, connection: any) -> (),
    size: (self: ScopeHandle) -> number,
    destroy: (self: ScopeHandle) -> (),
}

type Scope = ScopeHandle & { _connections: { any }, _count: number }

-- Private ----------------------------------------------------------------

local function pushConnection(self: Scope, conn: any): ()
    local idx = self._count + 1
    self._count = idx
    self._connections[idx] = conn
end

-- Public -----------------------------------------------------------------

local ScopeMeta = {}
ScopeMeta.__index = ScopeMeta

function ScopeMeta.on(self: Scope, source: any, fn: (...any) -> ()): Types.Connection
    local conn = source:on(fn)
    pushConnection(self, conn)
    return conn
end

function ScopeMeta.once(self: Scope, source: any, fn: (...any) -> ()): Types.Connection
    local conn = source:once(fn)
    pushConnection(self, conn)
    return conn
end

ScopeMeta.add = pushConnection

function ScopeMeta.size(self: Scope): number
    return self._count
end

function ScopeMeta.destroy(self: Scope): ()
    local conns = self._connections
    local count = self._count
    for i = 1, count do
        local conn = conns[i]
        conns[i] = nil
        if typeof(conn) == "RBXScriptConnection" then
            (conn :: RBXScriptConnection):Disconnect()
        elseif typeof(conn) == "table" and conn.disconnect then
            conn:disconnect()
        end
    end
    self._count = 0
end

table.freeze(ScopeMeta)

local ScopeModule = {}

function ScopeModule.create(): ScopeHandle
    return (setmetatable({ _connections = {}, _count = 0 }, ScopeMeta) :: any) :: ScopeHandle
end

return table.freeze(ScopeModule)
