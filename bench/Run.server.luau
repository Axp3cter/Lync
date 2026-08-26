--!strict
--!optimize 2
-- The bench place's server entry: measures every bench on the native side.

local Harness = require ("@bench/harness")

Harness.run ("server")
