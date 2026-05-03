--!strict
--!optimize 2
-- Batched connection lifecycle for Lync, RBXScriptConnection, and disconnect()-style objects.

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

-- Routes :on / :once through `methodName` so both call sites share insert + size bookkeeping.
local function attach(
    self: Scope,
    source: any,
    fn: (...any) -> (),
    methodName: string
): Types.Connection
    local conn = source[methodName](source, fn)
    pushConnection(self, conn)
    return conn
end

-- Public -----------------------------------------------------------------

local ScopeMeta = {}
ScopeMeta.__index = ScopeMeta

function ScopeMeta.on(self: Scope, source: any, fn: (...any) -> ()): Types.Connection
    return attach(self, source, fn, "on")
end

function ScopeMeta.once(self: Scope, source: any, fn: (...any) -> ()): Types.Connection
    return attach(self, source, fn, "once")
end

ScopeMeta.add = pushConnection

function ScopeMeta.size(self: Scope): number
    return self._count
end

--[[
    Disconnect every tracked source. The shape sniff handles three kinds:
    Roblox RBXScriptConnection (:Disconnect), Lync Connection (:disconnect),
    and tables exposing either capitalization.
]]
function ScopeMeta.destroy(self: Scope): ()
    local conns = self._connections
    local count = self._count
    for i = 1, count do
        local conn = conns[i]
        conns[i] = nil
        if typeof(conn) == "RBXScriptConnection" then
            (conn :: RBXScriptConnection):Disconnect()
        elseif typeof(conn) == "table" then
            if conn.disconnect then
                conn:disconnect()
            elseif conn.Disconnect then
                conn:Disconnect()
            end
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
