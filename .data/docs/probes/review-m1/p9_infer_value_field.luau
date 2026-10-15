--!strict
-- Types.Infer reads a `_value` property to recognise a codec, so a record with a field named
-- `_value` is inferred as that field's value type instead of a record.
-- Check: luau-lsp analyze --platform=roblox --flag:LuauSolverV2=true --definitions=@roblox=<defs> p9_infer_value_field.luau
local Lync = require("../../../../src")
local Types = require("../../../../src/types")
local t = Lync.types

local record = { _value = t.int(0, 9), name = t.string(8) }
type Value = Types.Infer<typeof(record)>
-- If Value were the record { _value: number, name: string }, the first line checks and the second fails.
local asRecord: Value = { _value = 1, name = "a" }
local asNumber: Value = 5
