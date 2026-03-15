--!strict
-- Types.luau — Shared type definitions for Lync. No runtime code.

export type ChannelState = {
    buff: buffer,
    cursor: number,
    size: number,
    refs: { Instance },
    lowFrames: number,
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
    reliability: ("reliable" | "unreliable")?,
    rateLimit: RateLimitConfig?,
    validate: ((data: T, player: Player) -> (boolean, string?))?,
}

export type QueryConfig<Req, Resp> = {
    request: Codec<Req>,
    response: Codec<Resp>,
    timeout: number?,
}

export type Registration = {
    id: number,
    name: string,
    baseName: string,
    codec: Codec<any>,
    reliability: "reliable" | "unreliable",
    kind: "packet" | "request" | "response",
    partner: number?,
    signal: any,
    rateLimit: RateLimitConfig?,
    validate: ((data: any, player: Player) -> (boolean, string?))?,
}

export type Connection = {
    disconnect: (self: Connection) -> (),
    connected: boolean,
}

return nil
