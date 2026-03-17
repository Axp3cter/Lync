--!strict
--!optimize 2
-- Batched connection lifecycle management.

-- Private ------------------------------------------------------------

local ScopeImpl = {}
ScopeImpl.__index = ScopeImpl

function ScopeImpl.add (self: any, conn: any): ()
    if not conn then
        return
    end

    local entries = self._entries
    local count = self._count + 1
    self._count = count
    entries[count] = conn
end

function ScopeImpl.listen (self: any, source: any, callback: (...any) -> ()): ()
    local conn = source:listen (callback)
    local entries = self._entries
    local count = self._count + 1
    self._count = count
    entries[count] = conn
end

function ScopeImpl.once (self: any, source: any, callback: (...any) -> ()): ()
    local conn = source:once (callback)
    local entries = self._entries
    local count = self._count + 1
    self._count = count
    entries[count] = conn
end

function ScopeImpl.listenAll (self: any, namespace: any, callback: (...any) -> ()): ()
    local conn = namespace:listenAll (callback)
    local entries = self._entries
    local count = self._count + 1
    self._count = count
    entries[count] = conn
end

function ScopeImpl.destroy (self: any): ()
    local entries = self._entries
    local count = self._count

    for i = 1, count do
        local conn = entries[i]
        entries[i] = nil

        if typeof (conn) == "RBXScriptConnection" then
            conn:Disconnect ()
        elseif conn.disconnect then
            conn:disconnect ()
        end
    end

    self._count = 0
end

table.freeze (ScopeImpl)

-- Public -------------------------------------------------------------

local Scope = {}

function Scope.create (): any
    return setmetatable ({ _entries = {}, _count = 0 }, ScopeImpl)
end

return table.freeze (Scope)
