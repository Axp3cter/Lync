--!strict
--!optimize 2
-- Every record the library made while a piece of work ran, for the suites that read them.

local Lync = require ("@src")
local Types = require ("@src/Types")

local Records = {}

-- Types ---------------------------------------------------------------

-- A record as a listener was handed it, kept because a caller reads it after the fact.
export type Held = { read kind: Types.LogKind, read message: string, read data: Types.LogData }

-- Public --------------------------------------------------------------

-- What the library said while `run` ran, in the order it said it.
function Records.made (run: () -> ()): { Held }
    local held: { Held } = {}

    local function take (kind: Types.LogKind, message: string, data: Types.LogData)
        table.insert (held, { kind = kind, message = message, data = data })
    end

    local link = Lync.onLog (take)

    --[[
        Caught only so the listener comes off before the throw carries on. One left attached would
        go on filing records against work it has nothing to do with.
    ]]
    local ok, thrown = pcall (run)
    link:disconnect ()

    if not ok then error (thrown, 0) end
    return held
end

return table.freeze (Records)
