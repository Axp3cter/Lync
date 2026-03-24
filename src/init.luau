--!strict
--!optimize 2
-- Lync: buffer networking for Roblox.

local RunService = game:GetService("RunService")

local Types      = require(script.Types)
local Channel    = require(script.internal.Channel)
local Registry   = require(script.internal.Registry)
local Pool       = require(script.internal.Pool)
local Middleware = require(script.internal.Middleware)
local Gate       = require(script.transport.Gate)
local Base       = require(script.codec.Base)
local Packet     = require(script.api.Packet)
local Query      = require(script.api.Query)
local Group      = require(script.api.Group)
local Scope      = require(script.api.Scope)

-- Codecs
local BoolC     = require(script.codec.primitive.Bool)
local NumberC   = require(script.codec.primitive.Number)
local Float16C  = require(script.codec.primitive.Float16)
local IntC      = require(script.codec.primitive.Int)
local StringC   = require(script.codec.datatype.String)
local BufferC   = require(script.codec.datatype.Buffer)
local VectorC   = require(script.codec.datatype.Vector)
local CFrameC   = require(script.codec.datatype.CFrame)
local ColorC    = require(script.codec.datatype.Color)
local InstanceC = require(script.codec.datatype.Instance)
local UDimC     = require(script.codec.datatype.UDim)
local NRC       = require(script.codec.datatype.NumberRange)
local RayC      = require(script.codec.datatype.Ray)
local RectC     = require(script.codec.datatype.Rect)
local IVC       = require(script.codec.datatype.IntVector)
local RegionC   = require(script.codec.datatype.Region)
local SeqC      = require(script.codec.datatype.Sequence)
local FloatC    = require(script.codec.meta.Float)
local EnumC     = require(script.codec.meta.Enum)
local NothingC  = require(script.codec.meta.Nothing)
local CustomC   = require(script.codec.meta.Custom)
local UnknownC  = require(script.codec.meta.Unknown)
local BitfieldC = require(script.codec.meta.Bitfield)
local AutoC     = require(script.codec.meta.Auto)
local OptionalC = require(script.codec.composite.Optional)
local TupleC    = require(script.codec.composite.Tuple)
local TaggedC   = require(script.codec.composite.Tagged)
local StructC   = require(script.codec.composite.Struct)
local ArrayC    = require(script.codec.composite.Array)
local MapC      = require(script.codec.composite.Map)

-- Constants -----------------------------------------------------------

local IS_SERVER = RunService:IsServer()

-- State ---------------------------------------------------------------

local _started       = false
local _flushRate     = 60
local _flushAccum    = 0
local _flushConn: RBXScriptConnection? = nil

-- Private -------------------------------------------------------------

local DROP = table.freeze({ _lyncDrop = true })
local ALL  = table.freeze({ _lyncAll = true })

local function except(...: any): any
    local excluded: { [Player]: boolean } = {}

    for i = 1, select("#", ...) do
        local arg = select(i, ...)
        if typeof(arg) == "Instance" and (arg :: Instance):IsA("Player") then
            excluded[arg :: Player] = true
        elseif typeof(arg) == "table" and (arg :: any)._lyncGroup then
            for player in (arg :: any)._members do
                excluded[player] = true
            end
        else
            error("[Lync] except: argument must be a Player or Group")
        end
    end

    return table.freeze({ _lyncExcept = true, _excluded = excluded })
end

local function setupFlush(): ()
    local flushFn: () -> ()

    if IS_SERVER then
        local Server = require(script.transport.Server)
        flushFn = function(): ()
            Server.flush()
        end
    else
        local Client = require(script.transport.Client)
        flushFn = function(): ()
            Client.flush()
        end
    end

    _flushConn = RunService.Heartbeat:Connect(function(dt: number)
        if _flushRate >= 60 then
            flushFn()
        else
            _flushAccum += dt
            local interval = 1 / _flushRate
            if _flushAccum >= interval then
                _flushAccum -= interval
                -- Prevent drift accumulation
                if _flushAccum >= interval then
                    _flushAccum = 0
                end
                flushFn()
            end
        end
    end)
end

-- Public --------------------------------------------------------------

local Lync: any = {}

-- Lifecycle -----------------------------------------------------------

function Lync.configure(options: Types.ConfigureOptions): ()
    if _started then
        error("[Lync] Lync.configure: must be called before Lync.start()")
    end

    if options.channelMaxSize then
        local size = options.channelMaxSize
        if size < 4096 or size > 1048576 then
            error("[Lync] Lync.configure: channelMaxSize must be 4096-1048576")
        end
        Channel.setMaxSize(size)
        Base.setMaxSize(size)
    end

    if options.validationDepth then
        local depth = options.validationDepth
        if depth < 4 or depth > 32 then
            error("[Lync] Lync.configure: validationDepth must be 4-32")
        end
        Gate.setDepth(depth)
    end

    if options.poolSize then
        local size = options.poolSize
        if size < 2 or size > 128 then
            error("[Lync] Lync.configure: poolSize must be 2-128")
        end
        Pool.setMaxSize(size)
    end

    if options.bandwidthLimit then
        Gate.configureBandwidth(
            options.bandwidthLimit.softLimit,
            options.bandwidthLimit.maxStrikes
        )
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
    if _started then
        error("[Lync] Lync.start: already started")
    end
    _started = true

    if IS_SERVER then
        local Server = require(script.transport.Server)
        Server.start()
    else
        local Client = require(script.transport.Client)
        Client.start()
    end

    setupFlush()
end

-- `Lync.started` is a read-only property backed by _started
Lync.started = false

-- Definitions ---------------------------------------------------------

Lync.packet = Packet.define
Lync.query  = Query.define
Lync.group  = Group.create
Lync.scope  = Scope.create

-- Targeting -----------------------------------------------------------

Lync.all    = ALL
Lync.except = except
Lync.DROP   = DROP

-- Middleware ----------------------------------------------------------

Lync.onSend    = Middleware.onSend
Lync.onReceive = Middleware.onReceive
Lync.onDrop    = Middleware.onDrop

-- Runtime control -----------------------------------------------------

function Lync.flush(): ()
    if not _started then
        error("[Lync] Lync.flush: must call Lync.start() first")
    end

    if IS_SERVER then
        local Server = require(script.transport.Server)
        Server.flush()
    else
        local Client = require(script.transport.Client)
        Client.flush()
    end

    -- Reset accumulator to prevent double-flush
    _flushAccum = 0
end

function Lync.flushRate(hz: number): ()
    if hz < 1 or hz > 60 then
        error("[Lync] Lync.flushRate: hz must be 1-60")
    end
    _flushRate = hz
    _flushAccum = 0
end

-- Stats ---------------------------------------------------------------

Lync.stats = table.freeze({
    player = function(player: Player): Types.PlayerStats?
        if not IS_SERVER then return nil end
        local Server = require(script.transport.Server)
        return Server.getPlayerStats(player)
    end,

    reset = function(): ()
        if IS_SERVER then
            local Server = require(script.transport.Server)
            Server.resetStats()
        end

        -- Reset per-registration stats
        for _, reg in Registry.all() do
            reg.bytesSent = 0
            reg.bytesReceived = 0
            reg.fires = 0
            reg.recvFires = 0
            reg.drops = 0
        end
    end,
})

-- Debug ---------------------------------------------------------------

Lync.debug = table.freeze({
    capture = function(_label: string?): ()
        -- TODO: Implement capture recording
    end,

    stop = function(): ()
        -- TODO: Implement capture stop
    end,

    dump = function(): ()
        -- TODO: Implement capture dump
    end,

    pending = function(): number
        return Query.pendingCount()
    end,

    registrations = function(): { any }
        local regs = Registry.all()
        local result = table.create(#regs)

        for i, reg in regs do
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

-- Codecs --------------------------------------------------------------

Lync.int             = IntC.int
Lync.float           = FloatC.float
Lync.f16             = Float16C.f16
Lync.f32             = NumberC.f32
Lync.f64             = NumberC.f64
Lync.bool            = BoolC.bool
Lync.string          = StringC
Lync.buff            = BufferC.buff
Lync.vec2            = VectorC.vec2
Lync.vec3            = VectorC.vec3
Lync.cframe          = CFrameC.cframe
Lync.color3          = ColorC.color3
Lync.inst            = InstanceC.inst
Lync.udim            = UDimC.udim
Lync.udim2           = UDimC.udim2
Lync.numberRange     = NRC.numberRange
Lync.rect            = RectC.rect
Lync.ray             = RayC.ray
Lync.region3         = RegionC.region3
Lync.region3int16    = RegionC.region3int16
Lync.vec2int16       = IVC.vec2int16
Lync.vec3int16       = IVC.vec3int16
Lync.numberSequence  = SeqC.numberSequence
Lync.colorSequence   = SeqC.colorSequence
Lync.struct          = StructC.struct
Lync.deltaStruct     = StructC.deltaStruct
Lync.array           = ArrayC.array
Lync.deltaArray      = ArrayC.deltaArray
Lync.map             = MapC.map
Lync.deltaMap        = MapC.deltaMap
Lync.optional        = OptionalC.optional
Lync.tuple           = TupleC.define
Lync.tagged          = TaggedC.define
Lync.enum            = EnumC.define
Lync.bitfield        = BitfieldC.define
Lync.custom          = CustomC.define
Lync.nothing         = NothingC.nothing
Lync.unknown         = UnknownC.unknown
Lync.auto            = AutoC.auto

-- Wrap in metatable for `Lync.started` property -----------------------

local LyncProxy = setmetatable({}, {
    __index = function(_self: any, key: string): any
        if key == "started" then
            return _started
        end
        return Lync[key]
    end,

    __newindex = function(): ()
        error("[Lync] Lync: module table is read-only")
    end,
})

return LyncProxy
