--!strict
--!optimize 2
-- O(1) disconnect signal with thread reuse and reentrancy-safe fire.

local Types = require(script.Parent.Parent.Types)

-- Constants --------------------------------------------------------------

local STATE_DISCONNECTED = 0
local STATE_CONNECTED = 1
local STATE_ONCE = 2

-- State ------------------------------------------------------------------

-- Single recyclable thread for async dispatch; saves coroutine.create per fire.
local _freeThread: thread? = nil

-- Private ----------------------------------------------------------------

-- pcall wrapper: a handler error must not consume the recycled thread, otherwise
-- every subsequent fire pays a coroutine.create until process restart.
local function passer(fn: (...any) -> (), ...): ()
    local thread = _freeThread
    _freeThread = nil
    local ok, err = pcall(fn, ...)
    _freeThread = thread
    if not ok then
        task.spawn(error, err)
    end
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
    _signal: SignalFields,
    _index: number,
}

type SignalFields = {
    _entries: { Entry },
    _count: number,
}

local EntryImpl = {}
EntryImpl.__index = EntryImpl

-- Swap-with-last for O(1) disconnect; the moved entry's _index is patched too.
local function disconnectEntry(entry: Entry): ()
    if entry._state == STATE_DISCONNECTED then
        return
    end

    entry._state = STATE_DISCONNECTED
    entry.connected = false

    local signal = entry._signal
    local entries = signal._entries
    local idx = entry._index
    local last = signal._count

    if idx < last then
        local moved = entries[last]
        entries[idx] = moved
        moved._index = idx
    end
    entries[last] = nil
    signal._count = last - 1
end

EntryImpl.disconnect = disconnectEntry
table.freeze(EntryImpl)

-- Auto-disconnects ONCE entries before invoking; chooses sync vs spawned thread.
local function invokeEntry(entry: Entry, sync: boolean, ...: any): ()
    local state = entry._state
    if state == STATE_DISCONNECTED then
        return
    end
    if state == STATE_ONCE then
        disconnectEntry(entry)
    end
    if sync then
        entry.fn(...)
    else
        spawnCallback(entry.fn, ...)
    end
end

local SignalImpl = {}
SignalImpl.__index = SignalImpl

local function newEntry(self: SignalFields, callback: (...any) -> (), state: number): Entry
    local idx = self._count + 1
    self._count = idx

    local entry: Entry = setmetatable({
        fn = callback,
        _state = state,
        connected = true,
        _signal = self,
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
    local count = self._count
    if count == 0 then
        return
    end

    local entries = self._entries

    -- Single-listener fast path skips the snapshot allocation.
    if count == 1 then
        invokeEntry(entries[1], sync, ...)
        return
    end

    --[[
        Re-entrancy: a handler may disconnect or add others mid-fire.
        Snapshot the entry list so the iteration view is stable.
    ]]
    local snapshot = table.create(count)
    table.move(entries, 1, count, 1, snapshot)

    for i = 1, count do
        invokeEntry(snapshot[i], sync, ...)
    end
end

function SignalImpl.fire(self: SignalFields, ...: any): ()
    dispatch(self, false, ...)
end

function SignalImpl.fireSync(self: SignalFields, ...: any): ()
    dispatch(self, true, ...)
end

function SignalImpl.count(self: SignalFields): number
    return self._count
end

function SignalImpl.hasListeners(self: SignalFields): boolean
    return self._count > 0
end

table.freeze(SignalImpl)

-- Public -----------------------------------------------------------------

local SignalModule = {}

function SignalModule.create(): Types.SignalLike
    return (setmetatable({ _entries = {}, _count = 0 }, SignalImpl) :: any) :: Types.SignalLike
end

return table.freeze(SignalModule)
