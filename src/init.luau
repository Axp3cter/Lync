--!strict
--!optimize 2
-- Lync: buffer networking for Roblox.

local RunService = game:GetService("RunService")

local Baseline = require(script.internal.Baseline)
local Bridge = require(script.transport.Bridge)
local Channel = require(script.internal.Channel)
local Gate = require(script.transport.Gate)
local Group = require(script.api.Group)
local Log = require(script.util.Log)
local Middleware = require(script.internal.Middleware)
local Packet = require(script.api.Packet)
local Player = require(script.util.Player)
local Pool = require(script.internal.Pool)
local Query = require(script.api.Query)
local Registry = require(script.internal.Registry)
local Scope = require(script.api.Scope)
local Types = require(script.Types)

local ArrayC = require(script.codec.composite.Array)
local AutoC = require(script.codec.meta.Auto)
local BitfieldC = require(script.codec.meta.Bitfield)
local BoolC = require(script.codec.primitive.Bool)
local BufferC = require(script.codec.datatype.Buffer)
local CFrameC = require(script.codec.datatype.CFrame)
local ColorC = require(script.codec.datatype.Color)
local CustomC = require(script.codec.meta.Custom)
local DeltaScalarC = require(script.codec.meta.DeltaScalar)
local EnumC = require(script.codec.meta.Enum)
local Float16C = require(script.codec.primitive.Float16)
local FloatC = require(script.codec.meta.Float)
local IVC = require(script.codec.datatype.IntVector)
local InstanceC = require(script.codec.datatype.Instance)
local IntC = require(script.codec.primitive.Int)
local MapC = require(script.codec.composite.Map)
local NRC = require(script.codec.datatype.NumberRange)
local NothingC = require(script.codec.meta.Nothing)
local NumberC = require(script.codec.primitive.Number)
local OptionalC = require(script.codec.composite.Optional)
local RayC = require(script.codec.datatype.Ray)
local RectC = require(script.codec.datatype.Rect)
local RegionC = require(script.codec.datatype.Region)
local SeqC = require(script.codec.datatype.Sequence)
local StringC = require(script.codec.datatype.String)
local StructC = require(script.codec.composite.Struct)
local TaggedC = require(script.codec.composite.Tagged)
local TupleC = require(script.codec.composite.Tuple)
local UDimC = require(script.codec.datatype.UDim)
local UnknownC = require(script.codec.meta.Unknown)
local VectorC = require(script.codec.datatype.Vector)
local ZintC = require(script.codec.primitive.Zint)

-- Public types -----------------------------------------------------------

export type Codec<T> = Types.Codec<T>
export type Connection = Types.Connection
export type Packet<T> = Packet.PacketHandle<T>
export type Query<Req, Resp> = Query.QueryHandle<Req, Resp>
export type Group = Group.GroupHandle
export type Scope = Scope.ScopeHandle
export type PacketOptions = Types.PacketOptions
export type QueryOptions = Types.QueryOptions
export type ConfigureOptions = Types.ConfigureOptions
export type RateLimitConfig = Types.RateLimitConfig
export type PacketStats = Types.PacketStats
export type PlayerStats = Types.PlayerStats

-- Constants --------------------------------------------------------------

local IS_SERVER = RunService:IsServer()

--[[
    Singleton-string brand on a single `_lyncKind` field: dispatch is one
    hash lookup at the same predicted slot, and the literals narrow on `==`.
]]
local ALL = table.freeze({ _lyncKind = "all" :: "all" })
local DROP = table.freeze({ _lyncKind = "drop" :: "drop" })

local CHANNEL_MAX_MIN, CHANNEL_MAX_MAX = 4096, 1048576
local DEPTH_MIN, DEPTH_MAX = 4, 32
local POOL_MIN, POOL_MAX = 2, 128
local FLUSH_HZ_MIN, FLUSH_HZ_MAX = 1, 60

-- State ------------------------------------------------------------------

-- Single table so the Heartbeat closure captures one LCT_VAL, not N LCT_REFs.
local flushState = {
    started = false,
    rate = FLUSH_HZ_MAX,
    accum = 0,
    conn = nil :: RBXScriptConnection?,
    transport = nil :: { flush: () -> () }?,
}

-- Private ----------------------------------------------------------------

local isPlayer = Player.is

type ExceptValue = { _lyncKind: "except", _excluded: { [Player]: boolean } }

local function except(...: any): ExceptValue
    local excluded: { [Player]: boolean } = {}

    for i = 1, select("#", ...) do
        local arg = select(i, ...)
        if isPlayer(arg) then
            excluded[arg :: Player] = true
        elseif typeof(arg) == "table" and arg._lyncKind == "group" then
            for player in arg._members do
                excluded[player] = true
            end
        else
            Log.error(`argument must be a Player or Group, got {typeof(arg)}`)
        end
    end

    return table.freeze({
        _lyncKind = "except" :: "except",
        _excluded = table.freeze(excluded),
    })
end

local function setupFlush(transport: { flush: () -> () }): ()
    flushState.transport = transport

    flushState.conn = RunService.Heartbeat:Connect(function(dt: number)
        local rate = flushState.rate
        if rate >= FLUSH_HZ_MAX then
            transport.flush()
            return
        end

        local accum = flushState.accum + dt
        local interval = 1 / rate
        if accum >= interval then
            -- Frame-stall guard: zero the accumulator instead of catching up.
            accum = if accum >= 2 * interval then 0 else accum - interval
            transport.flush()
        end
        flushState.accum = accum
    end)
end

-- Validates `value` in [min, max] and applies it; errors with a configure-formatted message.
local function applyOption(
    name: string,
    value: number?,
    min: number,
    max: number,
    apply: (number) -> ()
): ()
    if value == nil then
        return
    end
    if value < min or value > max then
        Log.error(`{name} must be {min}-{max}`)
    end
    apply(value)
end

-- Public -----------------------------------------------------------------

local Lync = {}

function Lync.configure(options: Types.ConfigureOptions): ()
    Log.assert(not flushState.started, "must be called before Lync.start()")

    applyOption(
        "channelMaxSize",
        options.channelMaxSize,
        CHANNEL_MAX_MIN,
        CHANNEL_MAX_MAX,
        Channel.setMaxSize
    )
    applyOption("validationDepth", options.validationDepth, DEPTH_MIN, DEPTH_MAX, Gate.setDepth)
    applyOption("poolSize", options.poolSize, POOL_MIN, POOL_MAX, Pool.setMaxSize)

    if options.bandwidthLimit then
        Gate.configureBandwidth(options.bandwidthLimit.softLimit, options.bandwidthLimit.maxStrikes)
    end

    if options.globalRateLimit then
        Gate.configureGlobalRateLimit(options.globalRateLimit.maxPerSecond)
    end

    if options.stats then
        Channel.enableStats()
    end
end

function Lync.start(): ()
    Log.assert(not flushState.started, "already started")
    flushState.started = true

    if IS_SERVER then
        local Server = require(script.transport.Server)
        Server.start()
        setupFlush(Server)
    else
        local Client = require(script.transport.Client)
        Client.start()
        setupFlush(Client)
    end
end

function Lync.flush(): ()
    Log.assert(flushState.started, "must call Lync.start() first")
    -- Bind to a local: bare `(expr).flush()` after a statement parses as a continuation.
    local transport = flushState.transport :: { flush: () -> () }
    transport.flush()
    flushState.accum = 0
end

function Lync.flushRate(hz: number): ()
    if hz < FLUSH_HZ_MIN or hz > FLUSH_HZ_MAX then
        Log.error(`hz must be {FLUSH_HZ_MIN}-{FLUSH_HZ_MAX}`)
    end
    flushState.rate = hz
    flushState.accum = 0
end

function Lync.isStarted(): boolean
    return flushState.started
end

-- Restore module state to post-require defaults. For tests / hot reload.
function Lync.reset(): ()
    if flushState.conn then
        flushState.conn:Disconnect()
        flushState.conn = nil
    end
    flushState.started = false
    flushState.rate = FLUSH_HZ_MAX
    flushState.accum = 0
    flushState.transport = nil

    Baseline.reset()
    Bridge.reset()
    Channel.resetGlobals()
    Gate.reset()
    Group.reset()
    Log.reset()
    Middleware.reset()
    Pool.reset()
    Registry.reset()
end

Lync.packet = Packet.define
Lync.query = Query.define
Lync.group = Group.create
Lync.scope = Scope.create

Lync.all = ALL
Lync.except = except
Lync.DROP = DROP

Lync.onSend = Middleware.onSend
Lync.onReceive = Middleware.onReceive
Lync.onDrop = Middleware.onDrop

Lync.stats = table.freeze({
    player = function(player: Player): Types.PlayerStats?
        if not IS_SERVER then
            return nil
        end
        local Server = require(script.transport.Server)
        return Server.getPlayerStats(player)
    end,

    reset = function(): ()
        if IS_SERVER then
            local Server = require(script.transport.Server)
            Server.resetStats()
        end
        for _, reg in Registry.all() do
            reg.bytesSent = 0
            reg.bytesReceived = 0
            reg.fires = 0
            reg.recvFires = 0
            reg.drops = 0
        end
    end,
})

Lync.debug = table.freeze({
    --[[
        Stubs reserved for capture/replay tooling. No-ops keep the API
        surface stable across versions with or without the recorder.
    ]]
    capture = function(_label: string?): () end,
    stop = function(): () end,
    dump = function(): () end,

    pending = function(): number
        return Query.pendingCount()
    end,

    registrations = function(): { any }
        -- Registry IDs are sequential 1..count and never freed, so get(i) is non-nil in range.
        local count = Registry.count()
        local result = table.create(count)
        for i = 1, count do
            local reg = Registry.get(i) :: Types.Registration
            result[i] = table.freeze({
                name = reg.name,
                id = reg.id,
                kind = reg.kind,
                isUnreliable = reg.isUnreliable,
            })
        end
        return table.freeze(result)
    end,
})

Lync.int = IntC.int
Lync.zint = ZintC.zint
Lync.float = FloatC.float
Lync.deltaInt = DeltaScalarC.deltaInt
Lync.deltaFloat = DeltaScalarC.deltaFloat
Lync.deltaVec3 = DeltaScalarC.deltaVec3
Lync.deltaCFrame = DeltaScalarC.deltaCFrame
Lync.f16 = Float16C.f16
Lync.f32 = NumberC.f32
Lync.f64 = NumberC.f64
Lync.bool = BoolC.bool
Lync.string = StringC
Lync.buff = BufferC.buff
Lync.vec2 = VectorC.vec2
Lync.vec3 = VectorC.vec3
Lync.cframe = CFrameC.cframe
Lync.color3 = ColorC.color3
Lync.inst = InstanceC.inst
Lync.udim = UDimC.udim
Lync.udim2 = UDimC.udim2
Lync.numberRange = NRC.numberRange
Lync.rect = RectC.rect
Lync.ray = RayC.ray
Lync.region3 = RegionC.region3
Lync.region3int16 = RegionC.region3int16
Lync.vec2int16 = IVC.vec2int16
Lync.vec3int16 = IVC.vec3int16
Lync.numberSequence = SeqC.numberSequence
Lync.colorSequence = SeqC.colorSequence
Lync.struct = StructC.struct
Lync.deltaStruct = StructC.deltaStruct
Lync.array = ArrayC.array
Lync.deltaArray = ArrayC.deltaArray
Lync.map = MapC.map
Lync.deltaMap = MapC.deltaMap
Lync.optional = OptionalC.optional
Lync.tuple = TupleC.define
Lync.tagged = TaggedC.define
Lync.enum = EnumC.define
Lync.bitfield = BitfieldC.define
Lync.custom = CustomC.define
Lync.nothing = NothingC.nothing
Lync.unknown = UnknownC.unknown
Lync.auto = AutoC.auto

return table.freeze(Lync)
