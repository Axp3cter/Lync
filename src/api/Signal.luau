--!strict
--!optimize 2
-- O(1) disconnect signal system with thread reuse and reentrancy-safe fire.

local Types = require(script.Parent.Parent.Types)

-- Constants --------------------------------------------------------------

local STATE_DISCONNECTED = 0
local STATE_CONNECTED = 1
local STATE_ONCE = 2

-- State ------------------------------------------------------------------

local _freeThread: thread? = nil

-- Private ----------------------------------------------------------------

local function passer(fn: (...any) -> (), ...): ()
    local thread = _freeThread
    _freeThread = nil
    fn(...)
    _freeThread = thread
end

local function yielder(): ()
    while true do
        passer(coroutine.yield())
    end
end

local function spawnCallback(fn: (...any) -> (), ...: any): ()
    if not _freeThread then
        _freeThread = coroutine.create(yielder)
        coroutine.resume(_freeThread :: thread)
    end
    task.spawn(_freeThread :: thread, fn, ...)
end

type Entry = {
    fn: (...any) -> (),
    _state: number,
    connected: boolean,
    _signalEntries: { Entry },
    _signalCount: { number },
    _index: number,
}

local EntryImpl = {}
EntryImpl.__index = EntryImpl

local function disconnectEntry(entry: Entry): ()
    if entry._state == STATE_DISCONNECTED then
        return
    end

    entry._state = STATE_DISCONNECTED
    entry.connected = false

    local entries = entry._signalEntries
    local countRef = entry._signalCount
    local idx, last = entry._index, countRef[1]

    if idx < last then
        local moved = entries[last]
        entries[idx] = moved
        moved._index = idx
    end
    entries[last] = nil
    countRef[1] = last - 1
end

EntryImpl.disconnect = disconnectEntry
table.freeze(EntryImpl)

type SignalFields = {
    _entries: { Entry },
    _count: { number },
}

local SignalImpl = {}
SignalImpl.__index = SignalImpl

local function newEntry(self: SignalFields, callback: (...any) -> (), state: number): Entry
    local countRef = self._count
    local idx = countRef[1] + 1
    countRef[1] = idx

    local entry: Entry = setmetatable({
        fn = callback,
        _state = state,
        connected = true,
        _signalEntries = self._entries,
        _signalCount = countRef,
        _index = idx,
    }, EntryImpl) :: any

    self._entries[idx] = entry
    return entry
end

function SignalImpl.connect(self: SignalFields, callback: (...any) -> ()): Types.Connection
    return newEntry(self, callback, STATE_CONNECTED) :: any
end

function SignalImpl.once(self: SignalFields, callback: (...any) -> ()): Types.Connection
    return newEntry(self, callback, STATE_ONCE) :: any
end

function SignalImpl.wait(self: SignalFields): ...any
    local running = coroutine.running()
    local conn: Types.Connection
    conn = SignalImpl.connect(self, function(...: any)
        conn:disconnect()
        task.spawn(running, ...)
    end)
    return coroutine.yield()
end

local function dispatch(self: SignalFields, sync: boolean, ...: any): ()
    local count = self._count[1]
    if count == 0 then
        return
    end

    local entries = self._entries

    if count == 1 then
        local entry = entries[1]
        local state = entry._state
        if state == STATE_ONCE then
            disconnectEntry(entry)
            if sync then
                entry.fn(...)
            else
                spawnCallback(entry.fn, ...)
            end
        elseif state == STATE_CONNECTED then
            if sync then
                entry.fn(...)
            else
                spawnCallback(entry.fn, ...)
            end
        end
        return
    end

    local snapshot = table.create(count)
    table.move(entries, 1, count, 1, snapshot)

    for i = 1, count do
        local entry = snapshot[i]
        local state = entry._state
        if state == STATE_ONCE then
            disconnectEntry(entry)
            if sync then
                entry.fn(...)
            else
                spawnCallback(entry.fn, ...)
            end
        elseif state == STATE_CONNECTED then
            if sync then
                entry.fn(...)
            else
                spawnCallback(entry.fn, ...)
            end
        end
    end
end

function SignalImpl.fire(self: SignalFields, ...: any): ()
    dispatch(self, false, ...)
end

function SignalImpl.fireSync(self: SignalFields, ...: any): ()
    dispatch(self, true, ...)
end

function SignalImpl.count(self: SignalFields): number
    return self._count[1]
end

function SignalImpl.hasListeners(self: SignalFields): boolean
    return self._count[1] > 0
end

table.freeze(SignalImpl)

-- Public -----------------------------------------------------------------

local SignalModule = {}

function SignalModule.create(): Types.SignalLike
    return (setmetatable({ _entries = {}, _count = { 0 } }, SignalImpl) :: any) :: Types.SignalLike
end

return table.freeze(SignalModule)
