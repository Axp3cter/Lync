--!strict
--!optimize 2
-- Lync: buffer networking for Roblox.

local RunService = game:GetService("RunService")

local Base = require(script.codec.Base)
local Channel = require(script.internal.Channel)
local Gate = require(script.transport.Gate)
local Group = require(script.api.Group)
local Middleware = require(script.internal.Middleware)
local Packet = require(script.api.Packet)
local Pool = require(script.internal.Pool)
local Query = require(script.api.Query)
local Registry = require(script.internal.Registry)
local Scope = require(script.api.Scope)
local Types = require(script.Types)
local Util = require(script.internal.Util)

local ArrayC = require(script.codec.composite.Array)
local AutoC = require(script.codec.meta.Auto)
local BitfieldC = require(script.codec.meta.Bitfield)
local BoolC = require(script.codec.primitive.Bool)
local BufferC = require(script.codec.datatype.Buffer)
local CFrameC = require(script.codec.datatype.CFrame)
local ColorC = require(script.codec.datatype.Color)
local CustomC = require(script.codec.meta.Custom)
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

-- Public types (re-exported so users can write `Lync.Packet<MyData>`) ---

export type Codec<T>          = Types.Codec<T>
export type Connection        = Types.Connection
export type Packet<T>         = Packet.PacketHandle<T>
export type Query<Req, Resp>  = Query.QueryHandle<Req, Resp>
export type Group             = Group.GroupHandle
export type Scope             = Scope.ScopeHandle
export type PacketOptions     = Types.PacketOptions
export type QueryOptions      = Types.QueryOptions
export type ConfigureOptions  = Types.ConfigureOptions
export type RateLimitConfig   = Types.RateLimitConfig
export type PacketStats       = Types.PacketStats
export type PlayerStats       = Types.PlayerStats

-- Constants --------------------------------------------------------------

local IS_SERVER = RunService:IsServer()

local DROP = table.freeze({ _lyncDrop = true })
local ALL = table.freeze({ _lyncAll = true })

local CHANNEL_MAX_MIN, CHANNEL_MAX_MAX = 4096, 1048576
local DEPTH_MIN, DEPTH_MAX = 4, 32
local POOL_MIN, POOL_MAX = 2, 128
local FLUSH_HZ_MIN, FLUSH_HZ_MAX = 1, 60

-- State ------------------------------------------------------------------

--[[
    Wrap mutable flush state in one table so the Heartbeat closure
    captures a single LCT_VAL upvalue instead of separate LCT_REF
    upvalues for each field.
]]
local _flushState = {
    started = false,
    rate = FLUSH_HZ_MAX,
    accum = 0,
    conn = nil :: RBXScriptConnection?,
    transport = nil :: { flush: () -> () }?,
}

-- Private ----------------------------------------------------------------

local isPlayer = Util.isPlayer

local function except(...: any): any
    local excluded: { [Player]: boolean } = {}

    for i = 1, select("#", ...) do
        local arg = select(i, ...)
        if isPlayer(arg) then
            excluded[arg :: Player] = true
        elseif typeof(arg) == "table" and arg._lyncGroup then
            for player in arg._members :: { [Player]: boolean } do
                excluded[player] = true
            end
        else
            error("[Lync] Lync.except: argument must be a Player or Group")
        end
    end

    return table.freeze({
        _lyncExcept = true,
        _excluded = table.freeze(excluded),
    })
end

local function setupFlush(): ()
    local transport: { flush: () -> () }
    if IS_SERVER then
        local Server = require(script.transport.Server)
        transport = { flush = Server.flush }
    else
        local Client = require(script.transport.Client)
        transport = { flush = Client.flush }
    end
    _flushState.transport = transport

    _flushState.conn = RunService.Heartbeat:Connect(function(dt: number)
        local rate = _flushState.rate
        if rate >= FLUSH_HZ_MAX then
            transport.flush()
            return
        end

        local accum = _flushState.accum + dt
        local interval = 1 / rate
        if accum >= interval then
            -- Drift guard: if we're more than one interval behind (frame
            -- stall) zero the accumulator instead of catching up.
            accum = if accum >= 2 * interval then 0 else accum - interval
            transport.flush()
        end
        _flushState.accum = accum
    end)
end

-- Public -----------------------------------------------------------------

local Lync = {}

function Lync.configure(options: Types.ConfigureOptions): ()
    if _flushState.started then
        error("[Lync] Lync.configure: must be called before Lync.start()")
    end

    local size = options.channelMaxSize
    if size then
        if size < CHANNEL_MAX_MIN or size > CHANNEL_MAX_MAX then
            error(
                `[Lync] Lync.configure: channelMaxSize must be {CHANNEL_MAX_MIN}-{CHANNEL_MAX_MAX}`
            )
        end
        Channel.setMaxSize(size)
        Base.setMaxSize(size)
    end

    local depth = options.validationDepth
    if depth then
        if depth < DEPTH_MIN or depth > DEPTH_MAX then
            error(`[Lync] Lync.configure: validationDepth must be {DEPTH_MIN}-{DEPTH_MAX}`)
        end
        Gate.setDepth(depth)
    end

    local poolSize = options.poolSize
    if poolSize then
        if poolSize < POOL_MIN or poolSize > POOL_MAX then
            error(`[Lync] Lync.configure: poolSize must be {POOL_MIN}-{POOL_MAX}`)
        end
        Pool.setMaxSize(poolSize)
    end

    if options.bandwidthLimit then
        Gate.configureBandwidth(options.bandwidthLimit.softLimit, options.bandwidthLimit.maxStrikes)
    end

    if options.globalRateLimit then
        Gate.configureGlobalRateLimit(options.globalRateLimit.maxPerSecond)
    end

    if options.stats then
        Channel.enableStats()
        if IS_SERVER then
            local Server = require(script.transport.Server)
            Server.enableStats()
        end
    end
end

function Lync.start(): ()
    if _flushState.started then
        error("[Lync] Lync.start: already started")
    end
    _flushState.started = true

    if IS_SERVER then
        local Server = require(script.transport.Server)
        Server.start()
    else
        local Client = require(script.transport.Client)
        Client.start()
    end

    setupFlush()
end

function Lync.flush(): ()
    if not _flushState.started then
        error("[Lync] Lync.flush: must call Lync.start() first")
    end
    -- start() is the only path that sets transport, so it's non-nil here.
    (_flushState.transport :: { flush: () -> () }).flush()
    _flushState.accum = 0
end

function Lync.flushRate(hz: number): ()
    if hz < FLUSH_HZ_MIN or hz > FLUSH_HZ_MAX then
        error(`[Lync] Lync.flushRate: hz must be {FLUSH_HZ_MIN}-{FLUSH_HZ_MAX}`)
    end
    _flushState.rate = hz
    _flushState.accum = 0
end

function Lync.isStarted(): boolean
    return _flushState.started
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
        for i = 1, Registry.count() do
            local reg = Registry.get(i)
            if reg then
                reg.bytesSent = 0
                reg.bytesReceived = 0
                reg.fires = 0
                reg.recvFires = 0
                reg.drops = 0
            end
        end
    end,
})

Lync.debug = table.freeze({
    capture = function(_label: string?): () end,
    stop = function(): () end,
    dump = function(): () end,

    pending = function(): number
        return Query.pendingCount()
    end,

    registrations = function(): { any }
        local count = Registry.count()
        local result = table.create(count)
        local n = 0
        for i = 1, count do
            local reg = Registry.get(i)
            if reg then
                n += 1
                result[n] = table.freeze({
                    name = reg.name,
                    id = reg.id,
                    kind = reg.kind,
                    isUnreliable = reg.isUnreliable,
                })
            end
        end
        return table.freeze(result)
    end,
})

Lync.int = IntC.int
Lync.float = FloatC.float
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
