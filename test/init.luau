--!strict
--!optimize 2
-- Test entry point.

local Runner = require(script.Runner)

-- Codec ------------------------------------------------------------------

require(script.codec["Primitive.test"])
require(script.codec["String.test"])
require(script.codec["Vector.test"])
require(script.codec["CFrame.test"])
require(script.codec["Color.test"])
require(script.codec["Instance.test"])
require(script.codec["Buffer.test"])
require(script.codec["Enum.test"])
require(script.codec["Float16.test"])
require(script.codec["Quantized.test"])
require(script.codec["Composite.test"])
require(script.codec["Special.test"])
require(script.codec["Bitfield.test"])
require(script.codec["Tagged.test"])
require(script.codec["Tuple.test"])

-- Core -------------------------------------------------------------------

require(script.core["Channel.test"])
require(script.core["Baseline.test"])
require(script.codec["Varint.test"])
require(script.core["Pool.test"])
require(script.core["Registry.test"])
require(script.core["Middleware.test"])

-- Event ------------------------------------------------------------------

require(script.event["Signal.test"])
require(script.event["Group.test"])

-- Transport --------------------------------------------------------------

require(script.transport["Compress.test"])
require(script.transport["Gate.test"])
require(script.transport["Integrity.test"])

-- Run --------------------------------------------------------------------

local isSuccess = Runner.run()

if not isSuccess then
    error("[Lync] Tests failed, see output above")
end

return isSuccess
