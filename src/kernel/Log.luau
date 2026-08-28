--!strict
--!optimize 2
-- The one record channel: everything the library says about itself, and who is listening.

local Catalog = require ("@src/kernel/Catalog")
local Listeners = require ("@src/kernel/Listeners")
local Threads = require ("@src/kernel/Threads")
local Types = require ("@src/Types")

local Log = {}

-- Constants -----------------------------------------------------------

-- Shared by every record whose site handed over nothing else, since one empty table is enough.
const NO_FACTS = table.freeze ({} :: Facts)

-- A name in braces. That is the whole of what a template may hold.
const HELD = "{(%w+)}"

-- Types ---------------------------------------------------------------

--[[
    Every key reaches the record's `data` under its own name, so a site and a caller hold one
    vocabulary and there is no mapping between them to keep in step.
]]
export type Facts = { [string]: unknown }

-- A raise on its way to the boundary that catches it.
export type Rejection = {
    read code: Catalog.Code,
    read facts: Facts,
}

-- State ---------------------------------------------------------------

--[[
    One list for the process, so a caller wires `onLog` once and hears everything. Two namespaces in
    one place are not two things anybody watching logs subscribes to separately.
]]
local records: Listeners.List<Types.LogKind, string, Types.LogData> = Listeners.list (Threads.spawn)

-- Private -------------------------------------------------------------

--[[
    The position comes from whoever calls in. The useful line is a caller's declaration site and
    never this one, and nothing here is frozen, so a listener that keeps a record has to copy it.
]]
local function said (kind: Types.LogKind, message: string, facts: Facts, file: string, line: number)
    local data = table.clone (facts) :: any
    data.file = file
    data.line = line

    Listeners.fan (records, kind, message, data :: Types.LogData)
end

--[[
    Taken where the call raised. A handler runs on the raising thread with the stack still standing
    under it, and that is the only moment a line inside a caller's listener can be read.
]]
local function traced (thrown: any): string return debug.traceback (tostring (thrown), 2) end

-- Public --------------------------------------------------------------

--[[
    A call run with its answer, and a raise turned into a record rather than the engine's report.
    The trace is the message, since the library has no idea what the caller was doing. The answer
    is why this is not `contained`: nobody waits on a listener, and a responder's return is the
    reply.
]]
function Log.caught (call: (...any) -> ...any, ...: any): (boolean, any)
    local ok, held = xpcall (call, traced, ...)
    if ok then return true, held end

    local file, line = debug.info (call, "sl")
    said ("error", held, NO_FACTS, file, line)
    return false, nil
end

--[[
    A call on a thread of its own, with whatever it raises reported rather than propagated. Every
    listener list is fanned through it, so a mistake in one cannot reach the caller who fired.
]]
function Log.contained <A...>(call: (A...) -> (), ...: A...)
    Threads.spawn (Log.caught :: any, call :: any, ...)
end

--[[
    One listener handed every payload a block carried, in the order it carried them, and caught a
    payload at a time rather than around the walk: a listener that comes apart on one is a listener
    still handed the next, which is what it would have been on a thread apiece.
]]
local function eaching (
    at: { number },
    call: (...any) -> (),
    count: number,
    values: { any },
    ...: any
)
    local index = at[1]
    while index < count do
        index += 1

        -- Put where the catch reads it before the call, since a call that raises never comes back.
        at[1] = index
        call (values[index], ...)
    end
end

--[[
    A walk caught once rather than an item at a time, resumed past whatever came apart. The walk
    keeps where it reached where the catch can read it, so a listener raising on the fifth is
    reported and the sixth is handed over: the same isolation, at one call rather than a count.
]]
local function walking (walk: any, call: (...any) -> (), count: number, ...: any)
    local at = { 0 }

    while at[1] < count do
        local ok, held = xpcall (walk, traced, at, call, count, ...)
        if ok then return end

        local file, line = debug.info (call, "sl")
        said ("error", held, NO_FACTS, file, line)
    end
end

--[[
    The same containment over a block's payloads rather than over one. A block of thirty carried to
    one listener was thirty threads and is now one, and what that costs is a listener parking on the
    fifth keeping the sixth waiting where the two used to race.
]]
function Log.contains (call: (...any) -> (), count: number, values: { any }, ...: any)
    Threads.spawn (walking :: any, eaching :: any, call :: any, count, values, ...)
end

--[[
    The same over three arrays that move together rather than one and some constants. A set tells a
    caller an id, the record it names, and what that record was. Caught an item at a time for the
    same reason the walk above is, and a settle of two hundred is one thread and not two.
]]
local function alongside (
    at: { number },
    call: (...any) -> (),
    count: number,
    ones: { any },
    twos: { any },
    threes: { any }
)
    while at[1] < count do
        at[1] += 1
        call (ones[at[1]], twos[at[1]], threes[at[1]])
    end
end

function Log.beside (
    call: (...any) -> (),
    count: number,
    ones: { any },
    twos: { any },
    threes: { any }
)
    Threads.spawn (walking :: any, alongside :: any, call :: any, count, ones, twos, threes)
end

--[[
    Something the library dropped and moved past. A caller reads these to learn what their schema or
    somebody else's client is doing, so a warning is never a fault and never a throw to come.
]]
function Log.warn (message: string, facts: Facts?)
    local file, line = debug.info (2, "sl")
    said ("warn", message, facts or NO_FACTS, file, line)
end

--[[
    A fault the library contained, and then the throw. Both, since a caller watching the channel and
    one reading a stack are two people and the record is all the first ever sees.
]]
function Log.error (message: string, facts: Facts?): never
    local file, line = debug.info (2, "sl")
    said ("error", message, facts or NO_FACTS, file, line)

    return error (message, 0)
end

-- Gated on a global a release build folds away, so a shipped place composes none of this.
function Log.debug (message: string, facts: Facts?)
    if not __DEV__ then return end

    local file, line = debug.info (2, "sl")
    said ("debug", message, facts or NO_FACTS, file, line)
end

-- A caller turned away, raised where they asked and recorded nowhere.
function Log.refuse (message: string): never return error (message, 0) end

--[[
    A rejection for the boundary above. It carries a code and facts and no line, because composing
    one walks a template on a path a hostile client decides how often to reach.
]]
function Log.reject (code: Catalog.Code, facts: Facts?): never
    return error (table.freeze ({ code = code, facts = facts or NO_FACTS }) :: Rejection, 0)
end

--[[
    A name with no fact behind it is left in its braces: a line saying `{path}` is a defect a reader
    reports, where one saying nothing at all is one they work around.
]]
function Log.line (code: Catalog.Code, facts: Facts): string
    local out = string.gsub (Catalog.entries[code].template, HELD, function (name: string): string
        local held = facts[name]
        return if held == nil then `{"{"}{name}{"}"}` else tostring (held)
    end)
    return out
end

-- Whatever the boundary caught, turned into the record a drop leaves behind.
function Log.dropped (thrown: unknown, about: Facts, kind: Types.LogKind?)
    local rejection = if typeof (thrown) == "table" then thrown :: Rejection else nil
    local entry = if rejection == nil then nil else Catalog.entries[rejection.code]

    local code: Catalog.Code = if entry == nil
        then Catalog.BOUNDS
        else (rejection :: Rejection).code
    local raised: Facts = if entry == nil
        then { said = tostring (thrown) }
        else (rejection :: Rejection).facts

    --[[
        A copy, since what follows merges the raise in and the facts are the caller's table. A
        record that wrote into its own argument is a promise this cannot make.
    ]]
    local facts = table.clone (about)
    for name, value in raised do
        facts[name] = value
    end
    facts.code = code

    --[[
        A frame that failed before naming a definition has no declaration site to point at, and a
        record is promised a file and a line, so the library's own name stands there.
    ]]
    local file = if typeof (facts.file) == "string" then facts.file :: string else "Lync"
    local line = if typeof (facts.line) == "number" then facts.line :: number else 1

    said (kind or "warn", Log.line (code, facts), facts, file, line)
end

--[[
    A listener, and the connection that ends it. Every registration on the channel goes through the
    same list the printer sits in, so a caller who takes the printer keeps the records.
]]
function Log.onLog (
    fn: (kind: Types.LogKind, message: string, data: Types.LogData) -> ()
): Types.Connection
    return Listeners.connect (records, fn)
end

--[[
    The printer, handed over rather than registered. It is a listener like any other and is first in
    the order because it is attached as this file loads, and a caller who wants to format records
    themselves disconnects it and attaches their own.
]]
Log.console = Listeners.connect (
    records,
    function (kind: Types.LogKind, message: string, data: Types.LogData)
        local at = `{data.file}:{data.line}`
        if kind == "debug" then
            print (`[lync] {at} {message}`)
            return
        end
        warn (`[lync] {at} {message}`)
    end
)

return table.freeze (Log)
