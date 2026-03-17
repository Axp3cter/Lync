--!strict
--!optimize 2
-- Shared type definitions.

export type ChannelState = {
    buff: buffer,
    cursor: number,
    size: number,
    refs: { Instance },
    lastId: number,
    countPos: number,
    itemCount: number,
    deltas: { [number]: any },
    prevDump: buffer?,
}

export type Codec<T> = {
    write: (ch: ChannelState, value: T) -> (),
    read: (src: buffer, pos: number, refs: { Instance }?) -> (T, number),
}

export type RateLimitConfig = {
    maxPerSecond: number,
    burstAllowance: number?,
}

export type PacketConfig<T> = {
    value: Codec<T>,
    unreliable: boolean?,
    rateLimit: RateLimitConfig?,
    validate: ((data: T, player: Player) -> (boolean, string?))?,
    maxPayloadBytes: number?,
}

export type QueryConfig<Req, Resp> = {
    request: Codec<Req>,
    response: Codec<Resp>,
    timeout: number?,
    rateLimit: RateLimitConfig?,
    validate: ((data: Req, player: Player) -> (boolean, string?))?,
}

export type Registration = {
    id: number,
    name: string,
    baseName: string,
    codec: Codec<any>,
    isUnreliable: boolean,
    kind: number,
    partner: number?,
    signal: any,
    rateLimit: RateLimitConfig?,
    validate: ((data: any, player: Player) -> (boolean, string?))?,
    needsGate: boolean,
    maxPayloadBytes: number?,
}

export type Connection = {
    disconnect: (self: Connection) -> (),
    connected: boolean,
}

return nil
