--!strict
--!optimize 2
-- Batched connection lifecycle management.

local Types = require(script.Parent.Parent.Types)

-- Public --------------------------------------------------------------

local Scope = {}

export type ScopeHandle = {
    on: (self: ScopeHandle, source: any, fn: (...any) -> ()) -> Types.Connection,
    once: (self: ScopeHandle, source: any, fn: (...any) -> ()) -> Types.Connection,
    add: (self: ScopeHandle, connection: any) -> (),
    destroy: (self: ScopeHandle) -> (),
}

local ScopeMeta = {}
ScopeMeta.__index = ScopeMeta

function ScopeMeta.on(self: any, source: any, fn: (...any) -> ()): Types.Connection
    local conn = source:on(fn)
    local conns = self._connections
    local idx = self._count + 1
    self._count = idx
    conns[idx] = conn
    return conn
end

function ScopeMeta.once(self: any, source: any, fn: (...any) -> ()): Types.Connection
    local conn = source:once(fn)
    local conns = self._connections
    local idx = self._count + 1
    self._count = idx
    conns[idx] = conn
    return conn
end

function ScopeMeta.add(self: any, connection: any): ()
    local idx = self._count + 1
    self._count = idx
    self._connections[idx] = connection
end

function ScopeMeta.destroy(self: any): ()
    local conns = self._connections
    local count = self._count

    for i = 1, count do
        local conn = conns[i]
        conns[i] = nil :: any

        --[[
            Support both Lync Connection (conn:disconnect())
            and RBXScriptConnection (conn:Disconnect()).
        ]]
        if typeof(conn) == "table" then
            if conn.disconnect then
                conn:disconnect()
            end
        elseif typeof(conn) == "RBXScriptConnection" then
            (conn :: RBXScriptConnection):Disconnect()
        end
    end

    self._count = 0
end

function Scope.create(): ScopeHandle
    return setmetatable({
        _connections = {},
        _count = 0,
    }, ScopeMeta) :: any
end

return table.freeze(Scope)
