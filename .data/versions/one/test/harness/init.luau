--!strict
--!optimize 2
-- What a suite declares: written cases and drawn properties.

local Rng = require("@self/Rng")

local Harness = {}

-- Constants -----------------------------------------------------------

-- Cases each drawn source runs, the same on every run. A run that can be narrowed is one that can
-- differ on the day it matters.
Harness.BUDGETS = table.freeze({
    leaves = 5000,
    kinds = 10000,
    schemas = 4000,
    encode = 10000,
    decode = 15000,
    model = 1000,
    -- A whole game per case, so far fewer of them: each is dozens of operations and settles.
    stateful = 300,
})

-- Types ---------------------------------------------------------------

export type Source = keyof<typeof(Harness.BUDGETS)>

export type Declaration =
    { read kind: "case", read name: string, read run: () -> () }
    | { read kind: "property", read name: string, read source: Source, read run: (Rng.Rng) -> () }

-- Public --------------------------------------------------------------

function Harness.case(name: string, run: () -> ()): Declaration
    return table.freeze({ kind = "case" :: "case", name = name, run = run })
end

-- A check asked of drawn values. The source names where the draws come from and how many are made.
function Harness.property(name: string, source: Source, run: (Rng.Rng) -> ()): Declaration
    local kind = "property" :: "property"
    return table.freeze({ kind = kind, name = name, source = source, run = run })
end

return table.freeze(Harness)
