--!strict
-- Shared type definitions for the Lync networking library.

export type ChannelState = {
    buff: buffer,
    cursor: number,
    size: number,
    refs: { Instance },
    refCount: number,
    lastId: number,
    countPos: number,
    itemCount: number,
    singleMode: boolean,
    singlePos: number,
    --[[
        Per-codec write-side delta state, keyed by deltaId. Shape is opaque
        and codec-internal: deltaStruct stores `{raw, len, segOff, segLen}`,
        deltaArray stores `{perIdx, length}`, deltaMap stores `{perKey}`,
        delta scalars store quantized previous values.
    ]]
    deltas: { [number]: any },
    prevDump: buffer?,
    prevDumpLen: number,
    currentPacket: string?,
}

export type Codec<T> = {
    write: (ch: ChannelState, value: T) -> (),
    read: (src: buffer, pos: number, refs: { Instance }?) -> (T, number),
}

--[[
    Optional metadata used by Gate (validation), Reader (max-item bound),
    Auto (type dispatch), and composite codecs (direct write/read fast path).
]]
export type InternalCodec<T> = {
    write: (ch: ChannelState, value: T) -> (),
    read: (src: buffer, pos: number, refs: { Instance }?) -> (T, number),
    _size: number?,
    _directWrite: ((b: buffer, offset: number, value: T) -> ())?,
    _directRead: ((b: buffer, offset: number) -> T)?,
    _isDelta: boolean?,
    --[[
        True if any nested codec is delta. Lets the broadcast hot path skip
        encode-once when delta state would diverge per-receiver.
    ]]
    _hasDelta: boolean?,
    _isBool: boolean?,
    _hasUnknown: boolean?,
    _min: number?,
    _max: number?,
    _isInteger: boolean?,
    _schema: { [string]: InternalCodec<T> }?,
    _typeCheck: string?,
    --[[
        Composite metadata: lets Gate recurse element/variant validation
        instead of falling through to the generic NaN/inf scan.
    ]]
    _isOptional: boolean?,
    _inner: InternalCodec<T>?,
    _isTagged: boolean?,
    _variants: { [string]: InternalCodec<T> }?,
    _tagField: string?,
    _isArray: boolean?,
    _element: InternalCodec<T>?,
    _maxCount: number?,
    _isMap: boolean?,
    _keyCodec: InternalCodec<T>?,
    _valueCodec: InternalCodec<T>?,
    _isTuple: boolean?,
    _elements: { InternalCodec<T> }?,
    _isEnum: boolean?,
    _enumValues: { [string]: number }?,
    _maxStringLength: number?,
}

export type RateLimitState = {
    tokens: number,
    lastRefill: number,
    lastAccepted: number,
}

--[[
    Token-bucket (maxPerSecond + optional burst) or cooldown (cooldown
    seconds between accepts). Mixing both forms is undefined behavior.
]]
export type RateLimitConfig = {
    maxPerSecond: number?,
    burst: number?,
    cooldown: number?,
}

--[[
    User-supplied per-packet validator. Returns (true, nil) on accept;
    (false, reason) on reject — the reason is forwarded to onDrop hooks.
]]
export type ValidateFn = (data: any, player: Player) -> (boolean, string?)

export type PacketOptions = {
    unreliable: boolean?,
    rateLimit: RateLimitConfig?,
    validate: ValidateFn?,
    maxPayloadBytes: number?,
    timestamp: ("frame" | "offset" | "full")?,
}

export type QueryOptions = {
    timeout: number?,
    rateLimit: RateLimitConfig?,
    validate: ValidateFn?,
}

export type Registration = {
    id: number,
    name: string,
    kind: number,
    codec: InternalCodec<any>,
    isUnreliable: boolean,
    -- Response registration id; set on REQUEST regs only.
    partner: number?,
    signal: SignalLike,
    rateLimit: RateLimitConfig?,
    validate: ValidateFn?,
    needsGate: boolean,
    maxPayloadBytes: number?,
    timestampMode: number,
    headerSize: number,
    _openFn: (ch: ChannelState, id: number) -> (),
    bytesSent: number,
    bytesReceived: number,
    fires: number,
    recvFires: number,
    drops: number,
}

export type SignalLike = {
    fire: (self: SignalLike, ...any) -> (),
    fireSync: (self: SignalLike, ...any) -> (),
    connect: (self: SignalLike, callback: (...any) -> ()) -> Connection,
    once: (self: SignalLike, callback: (...any) -> ()) -> Connection,
    wait: (self: SignalLike) -> ...any,
    count: (self: SignalLike) -> number,
    hasListeners: (self: SignalLike) -> boolean,
}

export type Connection = {
    connected: boolean,
    disconnect: (self: Connection) -> (),
}

export type ConfigureOptions = {
    channelMaxSize: number?,
    validationDepth: number?,
    poolSize: number?,
    bandwidthLimit: { softLimit: number, maxStrikes: number }?,
    globalRateLimit: { maxPerSecond: number }?,
    stats: boolean?,
}

export type PacketStats = {
    bytesSent: number,
    bytesReceived: number,
    fires: number,
    recvFires: number,
    drops: number,
}

export type PlayerStats = {
    bytesSent: number,
    bytesReceived: number,
}

--[[
    Server keys baselines per Player; client uses `false` since booleans are
    valid table keys but Players never collide with that.
]]
export type BaselineKey = Player | false

-- Type-only module: runtime table is empty so re-requires are cheap.
return table.freeze({})
