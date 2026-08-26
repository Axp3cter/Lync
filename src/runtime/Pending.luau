--!strict
--!optimize 2
-- Requests in flight: the id each waits under, the deadline it waits to, and every way out.

local Heap = require ("@src/kernel/Heap")
local Log = require ("@src/kernel/Log")
local Protocol = require ("@src/wire/Protocol")
local Types = require ("@src/Types")

local Pending = {}
Pending.__index = Pending

-- Constants -----------------------------------------------------------

-- Twice the live ceiling, so the walk for a free id always has somewhere to go and cannot fail.
const SPACE = Protocol.QUERY_CAP * 2

-- Types ---------------------------------------------------------------

--[[
    One request nobody has answered. Its deadline is here as well as in the heap, since a heap entry
    outlives its request: an id comes round a lap later and the entry popping then belongs to the
    one before it.
]]
type Entry = {
    read definition: string,
    read player: Player?,
    read opened: number,
    read at: number,
    read complete: Types.Outcome<any>,
}

export type Pending = {
    read open: (
        self: Pending,
        now: number,
        definition: string,
        player: Player?,
        timeout: number?,
        complete: Types.Outcome<any>
    ) -> number,
    read answer: (self: Pending, id: number, value: any) -> boolean,
    read fail: (self: Pending, id: number, code: Types.OutcomeCode, now: number) -> boolean,
    read sweep: (self: Pending, now: number) -> (),
    read rejectFor: (self: Pending, player: Player, now: number) -> (),
    read rejectAll: (self: Pending, now: number) -> (),
}

type Self = {
    namespace: string,
    live: { [number]: Entry },
    count: number,
    next: number,
    deadlines: Heap.Heap,
}

-- Private -------------------------------------------------------------

-- A request lifted out of the live set. Every way out goes through here, so one resolves once.
local function taken (self: Self, id: number): Entry?
    local entry = self.live[id]
    if entry == nil then return nil end

    self.live[id] = nil
    self.count -= 1
    return entry
end

-- Public --------------------------------------------------------------

function Pending.new (namespace: string): Pending
    local self: Self = {
        namespace = namespace,
        live = {},
        count = 0,
        next = 0,
        deadlines = Heap.new (),
    }
    return (setmetatable (self, Pending) :: any) :: Pending
end

-- A request, under the first id nothing is waiting on.
function Pending.open (
    self: Self,
    now: number,
    definition: string,
    player: Player?,
    timeout: number?,
    complete: Types.Outcome<any>
): number
    if self.count == Protocol.QUERY_CAP then
        Log.refuse (
            `{self.namespace} has {Protocol.QUERY_CAP} requests in flight, which is the ceiling`
        )
    end

    local id = self.next
    while self.live[id] ~= nil do
        id = (id + 1) % SPACE
    end
    self.next = (id + 1) % SPACE

    local at = now + (timeout or Protocol.QUERY_TIMEOUT)
    self.live[id] = {
        definition = definition,
        player = player,
        opened = now,
        at = at,
        complete = complete,
    }
    self.count += 1

    Heap.push (self.deadlines, at, id)
    return id
end

--[[
    The reply arrived. Answers whether anybody was waiting, an id nobody waits on being a reply to a
    request that already ended or a frame nobody here sent for.
]]
function Pending.answer (self: Self, id: number, value: any): boolean
    local entry = taken (self, id)
    if entry == nil then return false end

    entry.complete (true, value, nil)
    return true
end

--[[
    The request ended as one of the four outcomes. The elapsed time rides on all of them, a caller
    reading how long a leave took being owed the same number as one reading a timeout.
]]
function Pending.fail (self: Self, id: number, code: Types.OutcomeCode, now: number): boolean
    local entry = taken (self, id)
    if entry == nil then return false end

    entry.complete (
        false,
        code,
        table.freeze ({ definition = entry.definition, elapsed = now - entry.opened })
    )
    return true
end

-- Every deadline that has passed, and only the requests still waiting on one of them.
function Pending.sweep (self: Self, now: number)
    local heap = self.deadlines

    while true do
        local at, id = Heap.peek (heap)
        if at == nil or at > now then return end
        Heap.pop (heap)

        local entry = self.live[id :: number]
        if entry ~= nil and entry.at <= now then
            Pending.fail (self, id :: number, "timeout", now)
        end
    end
end

--[[
    Everything owed by somebody who has gone, named for what happened: a caller branching on a leave
    knows not to retry, where one told it timed out would.
]]
function Pending.rejectFor (self: Self, player: Player, now: number)
    local taking: { number } = {}
    for id, entry in self.live do
        if entry.player == player then table.insert (taking, id) end
    end

    for _, id in taking do
        Pending.fail (self, id, "leave", now)
    end
end

--[[
    Everything at once, which is a namespace closing. The live set is replaced before anything is
    answered, so a completion opening a request of its own lands in the new one and nothing in the
    old can be answered twice.
]]
function Pending.rejectAll (self: Self, now: number)
    local live = self.live

    self.live = {}
    self.count = 0

    for _, entry in live do
        entry.complete (
            false,
            "shutdown",
            table.freeze ({ definition = entry.definition, elapsed = now - entry.opened })
        )
    end
end

return table.freeze (Pending)
