--!strict
--!optimize 2
-- Batched connection lifecycle management.

local Types = require(script.Parent.Parent.Types)

type Connection = Types.Connection

-- Private -------------------------------------------------------------

type ScopeFields = {
    _entries: { any }, -- Connection | RBXScriptConnection
    _count: number,
}

local ScopeImpl = {}
ScopeImpl.__index = ScopeImpl

export type Scope = typeof(setmetatable({} :: ScopeFields, ScopeImpl))

function ScopeImpl.add(self: Scope, conn: any): ()
    if not conn then
        return
    end

    local entries = self._entries
    local count = self._count + 1
    self._count = count
    entries[count] = conn
end

function ScopeImpl.listen(self: Scope, source: any, callback: (...any) -> ()): ()
    local conn = source:listen(callback)
    local entries = self._entries
    local count = self._count + 1
    self._count = count
    entries[count] = conn
end

function ScopeImpl.once(self: Scope, source: any, callback: (...any) -> ()): ()
    local conn = source:once(callback)
    local entries = self._entries
    local count = self._count + 1
    self._count = count
    entries[count] = conn
end

function ScopeImpl.listenAll(self: Scope, namespace: any, callback: (...any) -> ()): ()
    local conn = namespace:listenAll(callback)
    local entries = self._entries
    local count = self._count + 1
    self._count = count
    entries[count] = conn
end

function ScopeImpl.destroy(self: Scope): ()
    local entries = self._entries
    local count = self._count

    for i = 1, count do
        local conn = entries[i]
        entries[i] = nil

        if typeof(conn) == "RBXScriptConnection" then
            conn:Disconnect()
        elseif conn.disconnect then
            conn:disconnect()
        end
    end

    self._count = 0
end

table.freeze(ScopeImpl)

-- Public --------------------------------------------------------------

local ScopeModule = {}

function ScopeModule.create(): Scope
    return setmetatable({
        _entries = {},
        _count = 0,
    }, ScopeImpl)
end

return table.freeze(ScopeModule)
