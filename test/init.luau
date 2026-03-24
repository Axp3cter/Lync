--!strict
--!optimize 2

-- Codec
require(script.codec["Varint.test"])
require(script.codec["Int.test"])
require(script.codec["Number.test"])
require(script.codec["Float16.test"])
require(script.codec["Bool.test"])
require(script.codec["String.test"])
require(script.codec["Buffer.test"])
require(script.codec["Struct.test"])
require(script.codec["Array.test"])
require(script.codec["Map.test"])
require(script.codec["Optional.test"])
require(script.codec["Tuple.test"])
require(script.codec["Tagged.test"])
require(script.codec["Enum.test"])
require(script.codec["Float.test"])
require(script.codec["Bitfield.test"])
require(script.codec["Nothing.test"])
require(script.codec["Custom.test"])
require(script.codec["Vector.test"])
require(script.codec["CFrame.test"])
require(script.codec["Color.test"])
require(script.codec["UDim.test"])
require(script.codec["Rect.test"])
require(script.codec["Ray.test"])
require(script.codec["NumberRange.test"])
require(script.codec["Region.test"])
require(script.codec["IntVector.test"])
require(script.codec["Instance.test"])
require(script.codec["Unknown.test"])
require(script.codec["Sequence.test"])
require(script.codec["Auto.test"])

-- Adversarial
require(script.adversarial["NaN.test"])
require(script.adversarial["Truncated.test"])
require(script.adversarial["SchemaValidation.test"])

-- Pipeline
require(script.pipeline["Xor.test"])
require(script.pipeline["MSB.test"])
require(script.pipeline["Delta.test"])

-- Transport
require(script.transport["Gate.test"])

-- API
require(script.api["Signal.test"])
require(script.api["Group.test"])
require(script.api["Scope.test"])

-- Internal
require(script.internal["Channel.test"])
require(script.internal["Registry.test"])
require(script.internal["Pool.test"])
require(script.internal["Baseline.test"])
require(script.internal["Middleware.test"])

return nil
