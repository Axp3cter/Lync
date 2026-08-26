--!strict
--!optimize 2
-- The test place's client entry: runs every suite this side owns.

local Harness = require ("@test/harness")

-- The client half of a run, which is the wire tree and this side of every live pair.
Harness.run ("client")
