--!strict
--!optimize 2
-- Pooled coroutines: a call runs on one immediately, and cannot reach whoever asked for it.

local Threads = {}

-- State ---------------------------------------------------------------

--[[
    A thread is taken per call and puts itself back when that call returns, so the pile grows to the
    deepest run of calls ever in flight at one moment and never past it.
]]
local idle: { thread } = {}

-- Private -------------------------------------------------------------

local function ran (call: (...any) -> (), ...: any)
    call (...)
    table.insert (idle, coroutine.running ())
end

--[[
    The first call arrives as this function's own arguments, so a fresh thread is resumed once and
    not twice. Every call after it arrives out of the yield.
]]
local function cycles (call: (...any) -> (), ...: any)
    ran (call, ...)
    while true do
        ran (coroutine.yield ())
    end
end

-- Public --------------------------------------------------------------

function Threads.spawn <A...>(call: (A...) -> (), ...: A...)
    local held = table.remove (idle)
    if held == nil then
        task.spawn (coroutine.create (cycles), call, ...)
        return
    end
    task.spawn (held, call, ...)
end

return table.freeze (Threads)
