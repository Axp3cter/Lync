--!strict
--!optimize 2
-- Explicit-precision float codecs: f32 (4B) and f64 (8B).

local Base = require(script.Parent.Parent.Base)

-- State ------------------------------------------------------------------

--[[
    Roblox is single-threaded, so a module-level scratch is safe to alias.
    Auto codec uses this to round-trip a float through f32 and check fidelity.
]]
local F32_SCRATCH = buffer.create(4)

-- Public -----------------------------------------------------------------

local Number = {}

Number.f32 = Base.define(4, buffer.writef32, buffer.readf32, { _typeCheck = "number" })
Number.f64 = Base.define(8, buffer.writef64, buffer.readf64, { _typeCheck = "number" })

Number._f32Scratch = F32_SCRATCH

return table.freeze(Number)
