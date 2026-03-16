--!strict
--!optimize 2
-- O(1) disconnect listener system with thread reuse.

local Types = require (script.Parent.Parent.Types)

type Connection = Types.Connection

-- Listener state: single numeric field for both connected and once checks.
local STATE_DISCONNECTED = 0
local STATE_CONNECTED = 1
local STATE_ONCE = 2

-- Private ----------------------------------------------------------------

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

-- Entry doubles as the Connection handle — 1 alloc per listener, not 2.
local EntryImpl = {}
EntryImpl.__index = EntryImpl

function EntryImpl.disconnect (self: any): ()
    if self._state == STATE_DISCONNECTED then
        return
    end

    self._state = STATE_DISCONNECTED
    self.connected = false

    local entries = self._signal._entries
    local count = self._signal._count
    local index = self._index

    if count == 0 or index > count then
        return
    end

    if index < count then
        local last = entries[count]
        entries[index] = last
        last._index = index
    end

    entries[count] = nil
    self._signal._count = count - 1
end

local SignalImpl = {}
SignalImpl.__index = SignalImpl

local function addEntry (self: any, callback: (...any) -> (), isOnce: boolean): Connection
    local count = self._count + 1
    self._count = count

    local entry = setmetatable ({
        fn = callback,
        _state = if isOnce then STATE_ONCE else STATE_CONNECTED,
        connected = true,
        _signal = self,
        _index = count,
    }, EntryImpl)

    self._entries[count] = entry
    return entry :: any
end

function SignalImpl.connect (self: any, callback: (...any) -> ()): Connection
    return addEntry (self, callback, false)
end

function SignalImpl.once (self: any, callback: (...any) -> ()): Connection
    return addEntry (self, callback, true)
end

function SignalImpl.wait (self: any): ...any
    local thread = coroutine.running ()
    local entry: any

    entry = addEntry (self, function (...: any): ()
        entry:disconnect ()
        task.spawn (thread, ...)
    end, true)

    return coroutine.yield ()
end

-- Dispatches to all listeners via task.spawn (safe for yielding handlers).
function SignalImpl.fire (self: any, ...: any): ()
    local entries = self._entries
    local count = self._count
    if count == 0 then
        return
    end

    -- Single listener: skip snapshot entirely.
    if count == 1 then
        local entry = entries[1]
        local state = entry._state
        if state == STATE_DISCONNECTED then
            return
        end

        spawn (entry.fn, ...)

        if state == STATE_ONCE then
            entry:disconnect ()
        end
        return
    end

    local snapshot = self._snapshot
    table.move (entries, 1, count, 1, snapshot)

    local tail = count + 1
    if snapshot[tail] ~= nil then
        snapshot[tail] = nil
    end

    for i = 1, count do
        local entry = snapshot[i]
        snapshot[i] = nil

        local state = entry._state
        if state == STATE_DISCONNECTED then
            continue
        end

        spawn (entry.fn, ...)

        if state == STATE_ONCE then
            entry:disconnect ()
        end
    end
end

-- Dispatches to all listeners synchronously without task.spawn.
-- Only safe when all listeners are guaranteed non-yielding.
function SignalImpl.fireSync (self: any, ...: any): ()
    local entries = self._entries
    local count = self._count
    if count == 0 then
        return
    end

    if count == 1 then
        local entry = entries[1]
        local state = entry._state
        if state == STATE_DISCONNECTED then
            return
        end

        entry.fn (...)

        if state == STATE_ONCE then
            entry:disconnect ()
        end
        return
    end

    local snapshot = self._snapshot
    table.move (entries, 1, count, 1, snapshot)

    local tail = count + 1
    if snapshot[tail] ~= nil then
        snapshot[tail] = nil
    end

    for i = 1, count do
        local entry = snapshot[i]
        snapshot[i] = nil

        local state = entry._state
        if state == STATE_DISCONNECTED then
            continue
        end

        entry.fn (...)

        if state == STATE_ONCE then
            entry:disconnect ()
        end
    end
end

function SignalImpl.disconnectAll (self: any): ()
    local entries = self._entries

    for i = 1, self._count do
        entries[i]._state = STATE_DISCONNECTED
        entries[i].connected = false
        entries[i] = nil
    end

    self._count = 0
end

-- Public -----------------------------------------------------------------

local Signal = {}

function Signal.create (): any
    return setmetatable ({ _entries = {}, _count = 0, _snapshot = {} }, SignalImpl)
end

return table.freeze (Signal)
