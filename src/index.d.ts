/// <reference types="@rbxts/types" />

declare namespace Lync {
    // ── Core Types ──────────────────────────────────────────────────

    interface Codec<T> {
        /** @hidden */ readonly _nominal_codec: T;
    }

    interface Connection {
        connected: boolean;
        disconnect(): void;
    }

    interface PacketStats {
        bytesSent: number;
        bytesReceived: number;
        fires: number;
        recvFires: number;
        drops: number;
    }

    interface PlayerStats {
        bytesSent: number;
        bytesReceived: number;
    }

    // ── Packet ──────────────────────────────────────────────────────

    interface PacketOptions<T> {
        unreliable?: boolean;
        rateLimit?: { maxPerSecond?: number; burst?: number } | { cooldown: number };
        validate?: (data: T, player: Player) => LuaTuple<[boolean, string?]>;
        maxPayloadBytes?: number;
        timestamp?: "frame" | "offset" | "full";
    }

    interface Packet<T> {
        send(this: Packet<T>, data: T, target?: Target): void;
        on(this: Packet<T>, fn: (data: T, sender?: Player, timestamp?: number) => void): Connection;
        once(this: Packet<T>, fn: (data: T, sender?: Player, timestamp?: number) => void): Connection;
        wait(this: Packet<T>): LuaTuple<[T, Player?, number?]>;
        name(this: Packet<T>): string;
        stats(this: Packet<T>): PacketStats;
    }

    // ── Query ───────────────────────────────────────────────────────

    interface QueryOptions<Req> {
        timeout?: number;
        rateLimit?: { maxPerSecond?: number; burst?: number };
        validate?: (data: Req, player: Player) => LuaTuple<[boolean, string?]>;
    }

    interface Query<Req, Resp> {
        handle(this: Query<Req, Resp>, fn: (request: Req, player?: Player) => Resp | undefined): Connection;
        request(this: Query<Req, Resp>, data: Req): Resp | undefined;
        request(this: Query<Req, Resp>, data: Req, target: Player): Resp | undefined;
        request(this: Query<Req, Resp>, data: Req, target: Target): Map<Player, Resp | undefined>;
        name(this: Query<Req, Resp>): string;
        stats(this: Query<Req, Resp>): PacketStats;
    }

    // ── Group ───────────────────────────────────────────────────────

    interface Group extends Iterable<Player> {
        add(this: Group, player: Player): boolean;
        remove(this: Group, player: Player): boolean;
        has(this: Group, player: Player): boolean;
        count(this: Group): number;
        destroy(this: Group): void;
    }

    // ── Scope ───────────────────────────────────────────────────────

    interface Scope {
        on<T>(this: Scope, source: Packet<T>, fn: (data: T, sender?: Player, timestamp?: number) => void): Connection;
        once<T>(this: Scope, source: Packet<T>, fn: (data: T, sender?: Player, timestamp?: number) => void): Connection;
        add(this: Scope, connection: Connection | RBXScriptConnection): void;
        destroy(this: Scope): void;
    }

    // ── Targets ─────────────────────────────────────────────────────

    type Target = Player | Player[] | Group | AllTarget | ExceptTarget;

    interface AllTarget {
        /** @hidden */ readonly _lyncAll: true;
    }

    interface ExceptTarget {
        /** @hidden */ readonly _lyncExcept: true;
    }

    // ── Codec Inference ─────────────────────────────────────────────

    type InferCodec<C> = C extends Codec<infer T> ? T : never;

    type InferSchema<S extends Record<string, Codec<unknown>>> = {
        [K in keyof S]: InferCodec<S[K]>;
    };

    // ── Callable Codecs ─────────────────────────────────────────────

    interface StringCodec extends Codec<string> {
        (maxLength: number): Codec<string>;
    }

    interface Vec2Codec extends Codec<Vector2> {
        (min: number, max: number, precision: number): Codec<Vector2>;
    }

    interface Vec3Codec extends Codec<Vector3> {
        (min: number, max: number, precision: number): Codec<Vector3>;
    }

    interface CFrameCodec extends Codec<CFrame> {
        (): Codec<CFrame>;
    }

    // ── Configure ───────────────────────────────────────────────────

    interface ConfigureOptions {
        channelMaxSize?: number;
        validationDepth?: number;
        poolSize?: number;
        bandwidthLimit?: { softLimit: number; maxStrikes: number };
        globalRateLimit?: { maxPerSecond: number };
        stats?: boolean;
    }

    // ── Drop Sentinel ───────────────────────────────────────────────

    interface DropSentinel {
        /** @hidden */ readonly _lyncDrop: true;
    }
}

interface LyncModule {
    // ── Lifecycle ────────────────────────────────────────────────────

    configure(this: void, options: Lync.ConfigureOptions): void;
    start(this: void): void;
    isStarted(this: void): boolean;

    // ── Definitions ─────────────────────────────────────────────────

    packet<T>(this: void, name: string, codec: Lync.Codec<T>, options?: Lync.PacketOptions<T>): Lync.Packet<T>;

    query<Req, Resp>(
        this: void,
        name: string,
        requestCodec: Lync.Codec<Req>,
        responseCodec: Lync.Codec<Resp>,
        options?: Lync.QueryOptions<Req>,
    ): Lync.Query<Req, Resp>;

    group(this: void, name: string): Lync.Group;
    scope(this: void): Lync.Scope;

    // ── Targeting ───────────────────────────────────────────────────

    readonly all: Lync.AllTarget;
    except(this: void, ...args: Array<Player | Lync.Group>): Lync.ExceptTarget;
    readonly DROP: Lync.DropSentinel;

    // ── Middleware ───────────────────────────────────────────────────

    onSend(this: void, fn: (data: unknown, name: string, player?: Player) => unknown): Lync.Connection;
    onReceive(this: void, fn: (data: unknown, name: string, player?: Player) => unknown): Lync.Connection;
    onDrop(this: void, fn: (player: Player, reason: string, name: string, data?: unknown) => void): Lync.Connection;

    // ── Runtime Control ─────────────────────────────────────────────

    flush(this: void): void;
    flushRate(this: void, hz: number): void;

    // ── Stats ───────────────────────────────────────────────────────

    readonly stats: {
        player(this: void, player: Player): Lync.PlayerStats | undefined;
        reset(this: void): void;
    };

    // ── Debug ───────────────────────────────────────────────────────

    readonly debug: {
        capture(this: void, label?: string): void;
        stop(this: void): void;
        dump(this: void): void;
        pending(this: void): number;
        registrations(this: void): ReadonlyArray<{
            name: string;
            id: number;
            kind: number;
            isUnreliable: boolean;
        }>;
    };

    // ── Number Codecs ───────────────────────────────────────────────

    int(this: void, min: number, max: number): Lync.Codec<number>;
    float(this: void, min: number, max: number, precision: number): Lync.Codec<number>;
    readonly f16: Lync.Codec<number>;
    readonly f32: Lync.Codec<number>;
    readonly f64: Lync.Codec<number>;
    readonly bool: Lync.Codec<boolean>;

    // ── String & Buffer ─────────────────────────────────────────────

    readonly string: Lync.StringCodec;
    readonly buff: Lync.Codec<buffer>;

    // ── Vectors & Spatial ───────────────────────────────────────────

    readonly vec2: Lync.Vec2Codec;
    readonly vec3: Lync.Vec3Codec;
    readonly cframe: Lync.CFrameCodec;
    readonly ray: Lync.Codec<Ray>;
    readonly rect: Lync.Codec<Rect>;
    readonly region3: Lync.Codec<Region3>;
    readonly region3int16: Lync.Codec<Region3int16>;
    readonly vec2int16: Lync.Codec<Vector2int16>;
    readonly vec3int16: Lync.Codec<Vector3int16>;

    // ── Roblox Types ────────────────────────────────────────────────

    readonly color3: Lync.Codec<Color3>;
    readonly inst: Lync.Codec<Instance>;
    readonly udim: Lync.Codec<UDim>;
    readonly udim2: Lync.Codec<UDim2>;
    readonly numberRange: Lync.Codec<NumberRange>;
    readonly numberSequence: Lync.Codec<NumberSequence>;
    readonly colorSequence: Lync.Codec<ColorSequence>;

    // ── Composites ──────────────────────────────────────────────────

    struct<S extends Record<string, Lync.Codec<unknown>>>(this: void, schema: S): Lync.Codec<Lync.InferSchema<S>>;
    deltaStruct<S extends Record<string, Lync.Codec<unknown>>>(this: void, schema: S): Lync.Codec<Lync.InferSchema<S>>;
    array<T>(this: void, element: Lync.Codec<T>, maxCount?: number): Lync.Codec<T[]>;
    deltaArray<T>(this: void, element: Lync.Codec<T>, maxCount?: number): Lync.Codec<T[]>;
    map<K, V>(this: void, keyCodec: Lync.Codec<K>, valueCodec: Lync.Codec<V>, maxCount?: number): Lync.Codec<Map<K, V>>;
    deltaMap<K, V>(this: void, keyCodec: Lync.Codec<K>, valueCodec: Lync.Codec<V>, maxCount?: number): Lync.Codec<Map<K, V>>;
    optional<T>(this: void, codec: Lync.Codec<T>): Lync.Codec<T | undefined>;
    tuple<T extends Lync.Codec<unknown>[]>(this: void, ...codecs: T): Lync.Codec<{ [K in keyof T]: Lync.InferCodec<T[K]> }>;
    tagged<Tag extends string, V extends Record<string, Lync.Codec<unknown>>>(
        this: void,
        tagField: Tag,
        variants: V,
    ): Lync.Codec<{ [K in keyof V & string]: { [F in Tag]: K } & Lync.InferCodec<V[K]> }[keyof V & string]>;

    // ── Meta ────────────────────────────────────────────────────────

    enum<T extends string[]>(this: void, ...values: T): Lync.Codec<T[number]>;
    bitfield(this: void, schema: Record<string, { type: "bool" } | { type: "uint"; width: number } | { type: "int"; width: number }>): Lync.Codec<Record<string, boolean | number>>;
    custom<T>(
        this: void,
        size: number,
        write: (b: buffer, offset: number, value: T) => void,
        read: (b: buffer, offset: number) => T,
        typeCheck?: string,
    ): Lync.Codec<T>;
    readonly nothing: Lync.Codec<undefined>;
    readonly unknown: Lync.Codec<unknown>;
    readonly auto: Lync.Codec<unknown>;
}

declare const Lync: LyncModule;
export = Lync;
