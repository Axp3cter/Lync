--!strict
--!optimize 2
-- Every record the library made while a piece of work ran, for the suites that read them.

local Log = require("@src/kernel/Log")
local Types = require("@src/Types")

local Records = {}

export type Held = { read kind: Types.LogKind, read message: string, read data: Types.LogData }

-- What the library said while `run` ran, in the order it said it. The listener comes off before
-- a throw carries on, so it never files records against work it has nothing to do with.
function Records.made(run: () -> ()): { Held }
    local held: { Held } = {}
    local link = Log.onLog(function(kind: Types.LogKind, message: string, data: Types.LogData)
        table.insert(held, { kind = kind, message = message, data = data })
    end)
    local ok, thrown = pcall(run)
    link:disconnect()
    if not ok then error(thrown, 0) end
    return held
end

return table.freeze(Records)
