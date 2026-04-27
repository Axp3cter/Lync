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
    deltas: { [number]: DeltaCacheEntry },
    prevDump: buffer?,
    prevDumpLen: number,
    currentPacket: string?,
}

export type DeltaCacheEntry = {
    raw: buffer,
    len: number,
}

export type Codec<T> = {
    write: (ch: ChannelState, value: T) -> (),
    read: (src: buffer, pos: number, refs: { Instance }?) -> (T, number),
}

--[[
    InternalCodec carries optional metadata used by Gate (validation),
    Reader (max-item bound), Auto (type dispatch), and composite codecs
    (direct write/read fast path).
]]
export type InternalCodec<T> = {
    write: (ch: ChannelState, value: T) -> (),
    read: (src: buffer, pos: number, refs: { Instance }?) -> (T, number),
    _size: number?,
    _directWrite: ((b: buffer, offset: number, value: T) -> ())?,
    _directRead: ((b: buffer, offset: number) -> T)?,
    _isDelta: boolean?,
    _isBool: boolean?,
    _hasUnknown: boolean?,
    _min: number?,
    _max: number?,
    _isInteger: boolean?,
    _schema: { [string]: InternalCodec<any> }?,
    _typeCheck: string?,
    --[[
        Composite-codec metadata. Gate uses these to recurse element /
        variant validation rather than fall through to a generic NaN scan.
    ]]
    _isOptional: boolean?,
    _inner: InternalCodec<any>?,
    _isTagged: boolean?,
    _variants: { [string]: InternalCodec<any> }?,
    _tagField: string?,
    _isArray: boolean?,
    _element: InternalCodec<any>?,
    _maxCount: number?,
    _isMap: boolean?,
    _keyCodec: InternalCodec<any>?,
    _valueCodec: InternalCodec<any>?,
    _isTuple: boolean?,
    _elements: { InternalCodec<any> }?,
    _isEnum: boolean?,
    _enumValues: { [string]: number }?,
}

export type RateLimitState = {
    tokens: number,
    lastRefill: number,
    lastAccepted: number,
}

--[[
    Token-bucket (maxPerSecond + optional burst) or cooldown (cooldown
    seconds between accepts). Mixing both forms is undefined.
]]
export type RateLimitConfig = {
    maxPerSecond: number?,
    burst: number?,
    cooldown: number?,
}

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
    Server keys baselines per Player; client uses `false` since booleans
    are valid table keys but Players never collide with that.
]]
export type BaselineKey = Player | false

return nil
