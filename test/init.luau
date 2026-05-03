--!strict
--!optimize 2
-- Aggregator: requires every spec file so its top-level describe() runs.

local Test = script

-- Unit: codec base ------------------------------------------------------

require(Test.unit.codec["Base.spec"])

-- Unit: codec primitives ------------------------------------------------

require(Test.unit.codec.primitive["Bool.spec"])
require(Test.unit.codec.primitive["Float16.spec"])
require(Test.unit.codec.primitive["Int.spec"])
require(Test.unit.codec.primitive["Number.spec"])
require(Test.unit.codec.primitive["Signed.spec"])
require(Test.unit.codec.primitive["Varint.spec"])
require(Test.unit.codec.primitive["Zint.spec"])

-- Unit: codec datatypes -------------------------------------------------

require(Test.unit.codec.datatype["Buffer.spec"])
require(Test.unit.codec.datatype["CFrame.spec"])
require(Test.unit.codec.datatype["Color.spec"])
require(Test.unit.codec.datatype["Instance.spec"])
require(Test.unit.codec.datatype["IntVector.spec"])
require(Test.unit.codec.datatype["NumberRange.spec"])
require(Test.unit.codec.datatype["Ray.spec"])
require(Test.unit.codec.datatype["Rect.spec"])
require(Test.unit.codec.datatype["Region.spec"])
require(Test.unit.codec.datatype["Sequence.spec"])
require(Test.unit.codec.datatype["String.spec"])
require(Test.unit.codec.datatype["UDim.spec"])
require(Test.unit.codec.datatype["Vector.spec"])

-- Unit: codec composites ------------------------------------------------

require(Test.unit.codec.composite["Array.spec"])
require(Test.unit.codec.composite["Map.spec"])
require(Test.unit.codec.composite["Optional.spec"])
require(Test.unit.codec.composite["Shared.spec"])
require(Test.unit.codec.composite["Struct.spec"])
require(Test.unit.codec.composite["Tagged.spec"])
require(Test.unit.codec.composite["Tuple.spec"])

-- Unit: codec meta ------------------------------------------------------

require(Test.unit.codec.meta["Auto.spec"])
require(Test.unit.codec.meta["Bitfield.spec"])
require(Test.unit.codec.meta["Custom.spec"])
require(Test.unit.codec.meta["DeltaScalar.spec"])
require(Test.unit.codec.meta["Enum.spec"])
require(Test.unit.codec.meta["Float.spec"])
require(Test.unit.codec.meta["Nothing.spec"])
require(Test.unit.codec.meta["Unknown.spec"])

-- Unit: internal --------------------------------------------------------

require(Test.unit.internal["Baseline.spec"])
require(Test.unit.internal["Channel.spec"])
require(Test.unit.internal["Middleware.spec"])
require(Test.unit.internal["Pool.spec"])
require(Test.unit.internal["Registry.spec"])
require(Test.unit.internal["Transport.spec"])

-- Unit: util ------------------------------------------------------------

require(Test.unit.util["Array.spec"])
require(Test.unit.util["Buffer.spec"])
require(Test.unit.util["Constants.spec"])
require(Test.unit.util["Log.spec"])
require(Test.unit.util["Player.spec"])
require(Test.unit.util["Quantize.spec"])
require(Test.unit.util["Quat.spec"])

-- Unit: transport -------------------------------------------------------

require(Test.unit.transport["Bridge.spec"])
require(Test.unit.transport["Client.spec"])
require(Test.unit.transport["Gate.spec"])
require(Test.unit.transport["Reader.spec"])
require(Test.unit.transport["Server.spec"])

-- Unit: api -------------------------------------------------------------

require(Test.unit.api["Group.spec"])
require(Test.unit.api["Packet.spec"])
require(Test.unit.api["Query.spec"])
require(Test.unit.api["Scope.spec"])
require(Test.unit.api["Signal.spec"])

-- Integration -----------------------------------------------------------

require(Test.integration["BatchFraming.spec"])
require(Test.integration["Broadcast.spec"])
require(Test.integration["DeltaCodecs.spec"])
require(Test.integration["Init.spec"])
require(Test.integration["Multiplayer.spec"])
require(Test.integration["Networking.spec"])
require(Test.integration["Pipeline.spec"])
require(Test.integration["Timestamps.spec"])
require(Test.integration["XorDelta.spec"])

-- Property --------------------------------------------------------------

require(Test.property["Codec.spec"])
require(Test.property["Composite.spec"])
require(Test.property["Delta.spec"])
require(Test.property["Wire.spec"])

-- Adversarial -----------------------------------------------------------

require(Test.adversarial["BoundsOverflow.spec"])
require(Test.adversarial["ExploitVectors.spec"])
require(Test.adversarial["Fuzz.spec"])
require(Test.adversarial["NaN.spec"])
require(Test.adversarial["Schema.spec"])
require(Test.adversarial["Truncated.spec"])

return nil
