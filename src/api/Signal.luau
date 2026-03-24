--!strict
--!optimize 2
-- O(1) disconnect signal system with thread reuse.

local Types = require(script.Parent.Parent.Types)

-- Constants -----------------------------------------------------------

local STATE_DISCONNECTED = 0
local STATE_CONNECTED    = 1
local STATE_ONCE         = 2

-- State ---------------------------------------------------------------

local _freeThread: thread? = nil

-- Private -------------------------------------------------------------

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

-- Entry type
type Entry = {
    fn: (...any) -> (),
    _state: number,
    connected: boolean,
    _signalEntries: { Entry },
    _signalCount: { number },
    _index: number,
}

-- EntryImpl metatable
local EntryImpl = {}
EntryImpl.__index = EntryImpl

function EntryImpl.disconnect(self: Entry): ()
    if self._state == STATE_DISCONNECTED then return end

    self._state = STATE_DISCONNECTED
    self.connected = false

    local entries = self._signalEntries
    local countRef = self._signalCount
    local idx = self._index
    local last = countRef[1]

    if idx < last then
        -- Swap-remove: move last entry to this slot
        local moved = entries[last]
        entries[idx] = moved
        moved._index = idx
    end

    entries[last] = nil :: any
    countRef[1] = last - 1
end

table.freeze(EntryImpl)

-- Public --------------------------------------------------------------

local SignalModule = {}

type SignalFields = {
    _entries: { Entry },
    _count: { number },
    _snapshot: { Entry },
}

local SignalImpl = {}
SignalImpl.__index = SignalImpl

function SignalImpl.connect(self: SignalFields, callback: (...any) -> ()): Types.Connection
    local countRef = self._count
    local idx = countRef[1] + 1
    countRef[1] = idx

    local entry: Entry = setmetatable({
        fn = callback,
        _state = STATE_CONNECTED,
        connected = true,
        _signalEntries = self._entries,
        _signalCount = countRef,
        _index = idx,
    }, EntryImpl) :: any

    self._entries[idx] = entry
    return entry :: any
end

function SignalImpl.once(self: SignalFields, callback: (...any) -> ()): Types.Connection
    local countRef = self._count
    local idx = countRef[1] + 1
    countRef[1] = idx

    local entry: Entry = setmetatable({
        fn = callback,
        _state = STATE_ONCE,
        connected = true,
        _signalEntries = self._entries,
        _signalCount = countRef,
        _index = idx,
    }, EntryImpl) :: any

    self._entries[idx] = entry
    return entry :: any
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

function SignalImpl.fire(self: SignalFields, ...: any): ()
    local count = self._count[1]
    if count == 0 then return end

    local entries = self._entries

    -- Single-listener fast path
    if count == 1 then
        local entry = entries[1]
        if entry._state == STATE_ONCE then
            EntryImpl.disconnect(entry)
            spawnCallback(entry.fn, ...)
        elseif entry._state == STATE_CONNECTED then
            spawnCallback(entry.fn, ...)
        end
        return
    end

    -- Multi-listener: snapshot to handle mid-fire disconnects
    local snapshot = self._snapshot
    table.move(entries, 1, count, 1, snapshot)

    for i = 1, count do
        local entry = snapshot[i]
        snapshot[i] = nil :: any

        if entry._state == STATE_ONCE then
            EntryImpl.disconnect(entry)
            spawnCallback(entry.fn, ...)
        elseif entry._state == STATE_CONNECTED then
            spawnCallback(entry.fn, ...)
        end
    end
end

function SignalImpl.fireSync(self: SignalFields, ...: any): ()
    local count = self._count[1]
    if count == 0 then return end

    local entries = self._entries

    if count == 1 then
        local entry = entries[1]
        if entry._state == STATE_ONCE then
            EntryImpl.disconnect(entry)
            entry.fn(...)
        elseif entry._state == STATE_CONNECTED then
            entry.fn(...)
        end
        return
    end

    local snapshot = self._snapshot
    table.move(entries, 1, count, 1, snapshot)

    for i = 1, count do
        local entry = snapshot[i]
        snapshot[i] = nil :: any

        if entry._state == STATE_ONCE then
            EntryImpl.disconnect(entry)
            entry.fn(...)
        elseif entry._state == STATE_CONNECTED then
            entry.fn(...)
        end
    end
end

table.freeze(SignalImpl)

function SignalModule.create(): any
    return setmetatable({
        _entries = {},
        _count = { 0 },
        _snapshot = {},
    }, SignalImpl)
end

return table.freeze(SignalModule)
