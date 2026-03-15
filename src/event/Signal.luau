--!strict
--!optimize 2
-- Signal.luau — O(1) disconnect listener system with thread reuse.

local Types = require (script.Parent.Parent.Types)

type Connection = Types.Connection

-- Private ----------------------------------------------------------------

-- Thread reuse pool
local _freeThread: thread? = nil

local function passer (fn: (...any) -> (), ...: any): ()
    local acquired = _freeThread
    _freeThread = nil
    fn (...)
    _freeThread = acquired
end

local function yielder (): ()
    while true do
        passer (coroutine.yield ())
    end
end

local function spawn (fn: (...any) -> (), ...: any): ()
    if not _freeThread then
        _freeThread = coroutine.create (yielder)
        coroutine.resume (_freeThread :: thread)
    end
    task.spawn (_freeThread :: thread, fn, ...)
end

-- Connection
local ConnectionImpl = {}
ConnectionImpl.__index = ConnectionImpl

function ConnectionImpl.disconnect (self: any): ()
    if not self.connected then
        return
    end

    self.connected = false
    self._signal:_swapRemove (self._index)
end

-- Signal
local SignalImpl = {}
SignalImpl.__index = SignalImpl

function SignalImpl._swapRemove (self: any, index: number): ()
    local entries = self._entries
    local count = self._count
    if count == 0 or index > count then
        return
    end

    if index < count then
        local last = entries[count]
        entries[index] = last
        last.conn._index = index
    end

    entries[count] = nil
    self._count = count - 1
end

local function addEntry (self: any, callback: (...any) -> (), isOnce: boolean): Connection
    local count = self._count + 1
    self._count = count

    local conn = setmetatable ({
        connected = true,
        _signal = self,
        _index = count,
    }, ConnectionImpl)

    self._entries[count] = {
        fn = callback,
        once = isOnce,
        conn = conn,
    }

    return conn :: any
end

function SignalImpl.connect (self: any, callback: (...any) -> ()): Connection
    return addEntry (self, callback, false)
end

function SignalImpl.once (self: any, callback: (...any) -> ()): Connection
    return addEntry (self, callback, true)
end

function SignalImpl.wait (self: any): ...any
    local thread = coroutine.running ()
    local conn: any

    conn = addEntry (self, function (...: any): ()
        conn:disconnect ()
        task.spawn (thread, ...)
    end, true)

    return coroutine.yield ()
end

function SignalImpl.fire (self: any, ...: any): ()
    local entries = self._entries
    local count = self._count
    local isDirty = false

    for i = 1, count do
        local entry = entries[i]
        if not entry then
            continue
        end

        spawn (entry.fn, ...)

        if entry.once then
            entry.conn.connected = false
            isDirty = true
        end
    end

    if isDirty then
        for i = self._count, 1, -1 do
            local entry = entries[i]
            if entry and not entry.conn.connected then
                self:_swapRemove (i)
            end
        end
    end
end

function SignalImpl.disconnectAll (self: any): ()
    local entries = self._entries

    for i = 1, self._count do
        local entry = entries[i]
        if entry then
            entry.conn.connected = false
            entries[i] = nil
        end
    end

    self._count = 0
end

-- Public -----------------------------------------------------------------

local Signal = {}

function Signal.create (): any
    return setmetatable ({ _entries = {}, _count = 0 }, SignalImpl)
end

return table.freeze (Signal)
