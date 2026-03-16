--!strict
--!optimize 2
-- Test entry point.

local Runner = require (script.Runner)

-- Codec ------------------------------------------------------------------

require (script.codec["Primitive.test"])
require (script.codec["String.test"])
require (script.codec["Vector.test"])
require (script.codec["CFrame.test"])
require (script.codec["Color.test"])
require (script.codec["Instance.test"])
require (script.codec["Buffer.test"])
require (script.codec["Enum.test"])
require (script.codec["Float16.test"])
require (script.codec["Quantized.test"])
require (script.codec["Composite.test"])
require (script.codec["Special.test"])
require (script.codec["Bitfield.test"])
require (script.codec["Tagged.test"])
require (script.codec["Tuple.test"])
require (script.codec["Varint.test"])
require (script.codec["Custom.test"])
require (script.codec["IntVector.test"])
require (script.codec["UDim.test"])
require (script.codec["NumberRange.test"])
require (script.codec["Rect.test"])
require (script.codec["Region.test"])
require (script.codec["Ray.test"])
require (script.codec["Sequence.test"])

-- Core -------------------------------------------------------------------

require (script.core["Channel.test"])
require (script.core["Baseline.test"])
require (script.core["Pool.test"])
require (script.core["Registry.test"])
require (script.core["Middleware.test"])

-- Event ------------------------------------------------------------------

require (script.event["Signal.test"])
require (script.event["Group.test"])
require (script.event["Namespace.test"])

-- Transport --------------------------------------------------------------

require (script.transport["Gate.test"])
require (script.transport["Integrity.test"])

-- Run --------------------------------------------------------------------

local isSuccess = Runner.run ()

if not isSuccess then
    error ("[Lync] Tests failed, see output above")
end

return isSuccess
