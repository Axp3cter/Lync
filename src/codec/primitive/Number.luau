--!strict
--!optimize 2
-- Explicit-precision float codecs: f32 and f64.

local Base = require(script.Parent.Parent.Base)

-- Constants --------------------------------------------------------------

-- Shared scratch for Auto codec's f32 round-trip test. Roblox is
-- single-threaded so a module-level scratch cannot be aliased.
local F32_SCRATCH = buffer.create(4)

-- Public -----------------------------------------------------------------

local Number = {}

Number.f32 = Base.define(4, buffer.writef32, buffer.readf32, { _typeCheck = "number" })
Number.f64 = Base.define(8, buffer.writef64, buffer.readf64, { _typeCheck = "number" })

Number._f32Scratch = F32_SCRATCH

return table.freeze(Number)
