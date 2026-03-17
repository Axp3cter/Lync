// Type declarations for Lync networking library.

// -- Utility types -----------------------------------------------------

// Expands mapped types in hover tooltips.
type Prettify<T> = { [K in keyof T]: T[K] } & {};

// -- Codec -------------------------------------------------------------

// Opaque codec handle. Carries the serialized type at the type level.
export interface Codec<T> {
    /** @hidden @deprecated Do not use. Only for type metadata. */
    readonly _nominal_Codec: T;
}

// Extracts the value type from a codec.
export type InferCodec<C> = C extends Codec<infer T> ? T : never;

// Maps a record of codecs to a record of their value types.
type InferSchema<S extends Record<string, Codec<unknown>>> = Prettify<{
    [K in keyof S]: InferCodec<S[K]>;
}>;

// Maps a tuple of codecs to a tuple of their value types.
type InferTuple<T extends readonly Codec<unknown>[]> = {
    [K in keyof T]: InferCodec<T[K]>;
};

// Infers the discriminated union from a tagged variant map.
type InferTagged<
    Tag extends string,
    V extends Record<string, Codec<unknown>>,
> = {
    [K in keyof V & string]: Prettify<InferCodec<V[K]> & { [T in Tag]: K }>;
}[keyof V & string];

// -- Connection --------------------------------------------------------

export interface Connection {
    readonly connected: boolean;
    disconnect(this: Connection): void;
}

// -- Config ------------------------------------------------------------

export interface RateLimitConfig {
    maxPerSecond: number;
    burstAllowance?: number;
}

export interface BoolFieldSpec {
    type: "bool";
}

export interface UintFieldSpec {
    type: "uint";
    width: number;
}

export interface IntFieldSpec {
    type: "int";
    width: number;
}

export type FieldSpec = BoolFieldSpec | UintFieldSpec | IntFieldSpec;

type InferFieldSpec<F extends FieldSpec> = F extends BoolFieldSpec
    ? boolean
    : number;

type InferBitfield<S extends Record<string, FieldSpec>> = Prettify<{
    [K in keyof S]: InferFieldSpec<S[K]>;
}>;

// -- Target descriptors ------------------------------------------------

export interface AllTarget {
    readonly _tag: "all";
}

export interface ExceptTarget {
    readonly _tag: "except";
    readonly _set: ReadonlyMap<Player, true>;
}

export interface GroupObject {
    readonly _tag: "group";
    add(this: GroupObject, player: Player): boolean;
    remove(this: GroupObject, player: Player): boolean;
    has(this: GroupObject, player: Player): boolean;
    count(this: GroupObject): number;
    forEach(this: GroupObject, fn: (player: Player) => void): void;
    getSet(this: GroupObject): ReadonlyMap<Player, true>;
    destroy(this: GroupObject): void;
}

export type Target = Player | AllTarget | ExceptTarget | GroupObject | Player[];

// -- Scope -------------------------------------------------------------

export interface Scope {
    add(this: Scope, conn: Connection | RBXScriptConnection): void;
    listen<T>(this: Scope, source: Packet<T>, callback: (data: T, sender: Player | undefined) => void): void;
    once<T>(this: Scope, source: Packet<T>, callback: (data: T, sender: Player | undefined) => void): void;
    listenAll(this: Scope, namespace: Namespace, callback: (name: string, data: unknown, sender: Player | undefined) => void): void;
    destroy(this: Scope): void;
}

// -- DROP sentinel -----------------------------------------------------

export interface DropSentinel {
    readonly _tag: "drop";
}

// -- Packet ------------------------------------------------------------

export interface PacketConfig<T> {
    value: Codec<T>;
    unreliable?: boolean;
    rateLimit?: RateLimitConfig;
    validate?: (data: T, player: Player) => LuaTuple<[boolean, string?]>;
    maxPayloadBytes?: number;
}

export interface Packet<T> {
    send(this: Packet<T>, data: T, target?: Target): void;
    listen(this: Packet<T>, callback: (data: T, sender: Player | undefined) => void): Connection;
    once(this: Packet<T>, callback: (data: T, sender: Player | undefined) => void): Connection;
    wait(this: Packet<T>): LuaTuple<[T, Player | undefined]>;
    disconnectAll(this: Packet<T>): void;
}

// -- Query -------------------------------------------------------------

export interface QueryConfig<Req, Resp> {
    request: Codec<Req>;
    response: Codec<Resp>;
    timeout?: number;
    rateLimit?: RateLimitConfig;
    validate?: (data: Req, player: Player) => LuaTuple<[boolean, string?]>;
}

export interface Query<Req, Resp> {
    listen(
        this: Query<Req, Resp>,
        callback: (request: Req, player: Player) => Resp | undefined,
    ): Connection;
    request(this: Query<Req, Resp>, data: Req): Resp | undefined;
    requestFrom(this: Query<Req, Resp>, player: Player, data: Req): Resp | undefined;
    requestAll(this: Query<Req, Resp>, data: Req): Map<Player, Resp | undefined>;
    requestList(
        this: Query<Req, Resp>,
        players: Player[],
        data: Req,
    ): Map<Player, Resp | undefined>;
    requestGroup(
        this: Query<Req, Resp>,
        group: GroupObject,
        data: Req,
    ): Map<Player, Resp | undefined>;
}

// -- Namespace ---------------------------------------------------------

export interface NamespaceConfig {
    packets?: Record<string, PacketConfig<unknown>>;
    queries?: Record<string, QueryConfig<unknown, unknown>>;
}

type InferPackets<P extends Record<string, PacketConfig<unknown>>> = {
    [K in keyof P]: P[K] extends PacketConfig<infer T> ? Packet<T> : never;
};

type InferQueries<Q extends Record<string, QueryConfig<unknown, unknown>>> = {
    [K in keyof Q]: Q[K] extends QueryConfig<infer Req, infer Resp>
        ? Query<Req, Resp>
        : never;
};

export interface Namespace {
    readonly packets: Record<string, Packet<unknown>>;
    readonly queries: Record<string, Query<unknown, unknown>>;
    listenAll(
        this: Namespace,
        callback: (name: string, data: unknown, sender: Player | undefined) => void,
    ): Connection;
    onSend(
        this: Namespace,
        handler: (data: unknown, name: string, player: Player | undefined) => unknown | undefined,
    ): () => void;
    onReceive(
        this: Namespace,
        handler: (data: unknown, name: string, player: Player | undefined) => unknown | undefined,
    ): () => void;
    disconnectAll(this: Namespace): void;
    destroy(this: Namespace): void;
    packetNames(this: Namespace): string[];
    queryNames(this: Namespace): string[];
}

// -- Lync --------------------------------------------------------------

declare namespace Lync {
    // Lifecycle
    export const VERSION: string;
    export function start(): void;

    // Definition
    export function definePacket<T>(name: string, config: PacketConfig<T>): Packet<T>;
    export function defineQuery<Req, Resp>(
        name: string,
        config: QueryConfig<Req, Resp>,
    ): Query<Req, Resp>;
    export function defineNamespace<
        P extends Record<string, PacketConfig<unknown>> = {},
        Q extends Record<string, QueryConfig<unknown, unknown>> = {},
    >(
        name: string,
        config: { packets?: P; queries?: Q },
    ): Namespace & InferPackets<P> & InferQueries<Q>;

    // Primitives
    export const u8: Codec<number>;
    export const u16: Codec<number>;
    export const u32: Codec<number>;
    export const i8: Codec<number>;
    export const i16: Codec<number>;
    export const i32: Codec<number>;
    export const f32: Codec<number>;
    export const f64: Codec<number>;
    export const bool: Codec<boolean>;
    export const f16: Codec<number>;

    // Datatypes
    const string: Codec<string>;
    export { string };
    export const vec2: Codec<Vector2>;
    export const vec3: Codec<Vector3>;
    export const cframe: Codec<CFrame>;
    export const color3: Codec<Color3>;
    export const inst: Codec<Instance>;
    export const buff: Codec<buffer>;
    export const udim: Codec<UDim>;
    export const udim2: Codec<UDim2>;
    export const numberRange: Codec<NumberRange>;
    export const rect: Codec<Rect>;
    export const vec2int16: Codec<Vector2int16>;
    export const vec3int16: Codec<Vector3int16>;
    export const region3: Codec<Region3>;
    export const region3int16: Codec<Region3int16>;
    export const ray: Codec<Ray>;
    export const numberSequence: Codec<NumberSequence>;
    export const colorSequence: Codec<ColorSequence>;

    // Composites
    export function struct<S extends Record<string, Codec<unknown>>>(schema: S): Codec<InferSchema<S>>;
    export function deltaStruct<S extends Record<string, Codec<unknown>>>(schema: S): Codec<InferSchema<S>>;
    export function array<T>(element: Codec<T>, maxCount?: number): Codec<T[]>;
    export function deltaArray<T>(element: Codec<T>, maxCount?: number): Codec<T[]>;
    export function map<K extends defined, V>(key: Codec<K>, value: Codec<V>, maxCount?: number): Codec<Map<K, V>>;
    export function deltaMap<K extends defined, V>(key: Codec<K>, value: Codec<V>, maxCount?: number): Codec<Map<K, V>>;
    export function optional<T>(inner: Codec<T>): Codec<T | undefined>;

    // Meta
    function _enum<T extends string>(...values: T[]): Codec<T>;
    export { _enum as enum };
    export function quantizedFloat(min: number, max: number, precision: number): Codec<number>;
    export function quantizedVec3(min: number, max: number, precision: number): Codec<Vector3>;
    export function bitfield<S extends Record<string, FieldSpec>>(schema: S): Codec<InferBitfield<S>>;
    export function tagged<Tag extends string, V extends Record<string, Codec<unknown>>>(
        tagField: Tag,
        variants: V,
    ): Codec<InferTagged<Tag, V>>;
    export function tuple<T extends Codec<unknown>[]>(...codecs: T): Codec<InferTuple<T>>;
    export function custom<T>(
        size: number,
        write: (b: buffer, offset: number, value: T) => void,
        read: (b: buffer, offset: number) => T,
    ): Codec<T>;
    export function boundedString(maxLength: number): Codec<string>;
    export const nothing: Codec<undefined>;
    export const unknown: Codec<unknown>;
    export const auto: Codec<unknown>;

    // Hooks
    export function onDrop(
        callback: (player: Player, reason: string, packetName: string, data: unknown) => void,
    ): () => void;
    export function onSend(
        handler: (data: unknown, name: string, player: Player | undefined) => unknown | DropSentinel | undefined,
    ): () => void;
    export function onReceive(
        handler: (data: unknown, name: string, player: Player | undefined) => unknown | DropSentinel | undefined,
    ): () => void;

    // Target descriptors
    export const all: AllTarget;
    export function except(...players: Player[]): ExceptTarget;

    // Middleware sentinel
    export const DROP: DropSentinel;

    // Groups
    export function createGroup(name: string): GroupObject;

    // Scope
    export function scope(): Scope;

    // Configuration
    export function setChannelMaxSize(bytes: number): void;
    export function setValidationDepth(depth: number): void;
    export function setPoolSize(count: number): void;

    // Introspection
    export function queryPendingCount(): number;
}

export default Lync;
