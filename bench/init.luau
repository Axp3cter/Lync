--!strict
--!optimize 2
-- Benchmark entry point.

local Runner = require(script.Runner)

-- Codec ------------------------------------------------------------------

require(script.codec["Primitive.bench"])
require(script.codec["Composite.bench"])

-- Core -------------------------------------------------------------------

require(script.codec["Varint.bench"])
require(script.core["Compress.bench"])

-- Run --------------------------------------------------------------------

Runner.run()

return true
