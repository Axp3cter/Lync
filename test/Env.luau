--!strict
--!optimize 2
-- Centralized test environment. Specs require this once to get the
-- runner, sandbox, helpers, and the Lync module + every internal module.

local Test = script.Parent
local LyncRoot = Test.Parent

local Lync = require(LyncRoot)

local Random = require(Test.runner.Random)
local Runner = require(Test.runner)

local ChannelHelper = require(Test.support.Channel)
local Codecs = require(Test.support.Codecs)
local Fixtures = require(Test.support.Fixtures)
local MockBridge = require(Test.support.MockBridge)
local Players = require(Test.support.Players)
local Sandbox = require(Test.support.Sandbox)
local Wire = require(Test.support.Wire)

local Internal = {
    Types = require(LyncRoot.Types),
    Base = require(LyncRoot.codec.Base),
    Shared = require(LyncRoot.codec.composite.Shared),
    Signed = require(LyncRoot.codec.primitive.Signed),
    Varint = require(LyncRoot.codec.primitive.Varint),
    Channel = require(LyncRoot.internal.Channel),
    Baseline = require(LyncRoot.internal.Baseline),
    Middleware = require(LyncRoot.internal.Middleware),
    Pool = require(LyncRoot.internal.Pool),
    Registry = require(LyncRoot.internal.Registry),
    Transport = require(LyncRoot.internal.Transport),
    -- internal.Util was split into util.Player (Player.is) and util.Array (Array.swapRemove).
    Player = require(LyncRoot.util.Player),
    Array = require(LyncRoot.util.Array),
    Log = require(LyncRoot.util.Log),
    Bridge = require(LyncRoot.transport.Bridge),
    Gate = require(LyncRoot.transport.Gate),
    Reader = require(LyncRoot.transport.Reader),
    Server = require(LyncRoot.transport.Server),
    Client = require(LyncRoot.transport.Client),
    Group = require(LyncRoot.api.Group),
    Packet = require(LyncRoot.api.Packet),
    Query = require(LyncRoot.api.Query),
    Scope = require(LyncRoot.api.Scope),
    Signal = require(LyncRoot.api.Signal),
}

local Env = {
    Lync = Lync,

    -- Runner exports (destructure-friendly)
    describe = Runner.describe,
    it = Runner.it,
    beforeEach = Runner.beforeEach,
    afterEach = Runner.afterEach,
    beforeAll = Runner.beforeAll,
    afterAll = Runner.afterAll,
    expect = Runner.expect,

    Random = Random,
    Internal = Internal,

    -- Support modules
    Sandbox = Sandbox,
    Codecs = Codecs,
    Channel = ChannelHelper,
    Wire = Wire,
    Players = Players,
    Fixtures = Fixtures,
    MockBridge = MockBridge,
}

return table.freeze(Env)
