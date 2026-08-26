--!strict
--!optimize 2
-- The bench place's client entry: measures every bench on the interpreted side.

local Harness = require ("@bench/harness")

Harness.run ("client")
