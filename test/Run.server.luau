--!strict
--!optimize 2
-- The test place's server entry: runs every suite this side owns.

local Harness = require ("@test/harness")

-- Pass a seed as the second argument to replay a failure a run reported.
Harness.run ("server")
