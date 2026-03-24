--!strict
--!optimize 2
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
    deltas: { [number]: any },
    prevDump: buffer?,
    prevDumpLen: number,
    currentPacket: string?,
}

export type Codec<T> = {
    write: (ch: ChannelState, value: T) -> (),
    read: (src: buffer, pos: number, refs: { Instance }?) -> (T, number),
}

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
}

export type RateLimitState = {
    tokens: number,
    lastRefill: number,
    lastAccepted: number,
}

export type RateLimitConfig = {
    maxPerSecond: number?,
    burst: number?,
    cooldown: number?,
}

export type PacketOptions = {
    unreliable: boolean?,
    rateLimit: RateLimitConfig?,
    validate: ((data: any, player: Player) -> (boolean, string?))?,
    maxPayloadBytes: number?,
    timestamp: string?,
}

export type QueryOptions = {
    timeout: number?,
    rateLimit: RateLimitConfig?,
    validate: ((data: any, player: Player) -> (boolean, string?))?,
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
    validate: ((data: any, player: Player) -> (boolean, string?))?,
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
    connect: (self: SignalLike, callback: (...any) -> ()) -> Connection,
}

export type Connection = {
    connected: boolean,
    disconnect: (self: Connection) -> (),
}

export type ConfigureOptions = {
    channelMaxSize: number?,
    validationDepth: number?,
    poolSize: number?,
    bandwidthLimit: {
        softLimit: number,
        maxStrikes: number,
    }?,
    globalRateLimit: {
        maxPerSecond: number,
    }?,
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

return nil
