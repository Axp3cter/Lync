--!strict
--!optimize 2
-- Hermetic state reset for stateful src modules. Call resetAll() in beforeEach.

local Lync = script.Parent.Parent.Parent

local Base = require(Lync.codec.Base)
local Baseline = require(Lync.internal.Baseline)
local Bridge = require(Lync.transport.Bridge)
local Channel = require(Lync.internal.Channel)
local Gate = require(Lync.transport.Gate)
local Group = require(Lync.api.Group)
local Log = require(Lync.util.Log)
local Middleware = require(Lync.internal.Middleware)
local Pool = require(Lync.internal.Pool)
local Reader = require(Lync.transport.Reader)
local Registry = require(Lync.internal.Registry)
local Shared = require(Lync.codec.composite.Shared)

-- Public -----------------------------------------------------------------

local Sandbox = {}

--[[
    Reset every stateful src module to its post-require defaults so each
    test body starts from a known baseline regardless of what previous
    tests did. Call from beforeEach().
]]
function Sandbox.resetAll(): ()
    Registry.reset()
    Baseline.reset()
    Channel.resetGlobals()
    Base.reset()
    Pool.reset()
    Middleware.reset()
    Gate.reset()
    Group.reset()
    Bridge.reset()
    Reader.reset()
    Log.reset()
    Shared.reset()
end

Sandbox.resetRegistry = Registry.reset
Sandbox.resetBaseline = Baseline.reset
Sandbox.resetChannelGlobals = Channel.resetGlobals
Sandbox.resetBase = Base.reset
Sandbox.resetPool = Pool.reset
Sandbox.resetMiddleware = Middleware.reset
Sandbox.resetGate = Gate.reset
Sandbox.resetGroup = Group.reset
Sandbox.resetBridge = Bridge.reset
Sandbox.resetReader = Reader.reset
Sandbox.resetLog = Log.reset
Sandbox.resetShared = Shared.reset

return table.freeze(Sandbox)
