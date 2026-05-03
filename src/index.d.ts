/// <reference types="@rbxts/types" />

declare namespace Lync {
    // ── Core types ──────────────────────────────────────────────────────

    /**
     * Opaque codec brand. The `_nominal_codec` field never exists at
     * runtime; it ties the generic parameter to a unique nominal type so
     * `Codec<number>` and `Codec<string>` can't be assigned to each other.
     */
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

    type RateLimitConfig =
        | { maxPerSecond: number; burst?: number }
        | { cooldown: number };

    // ── Packet ──────────────────────────────────────────────────────────

    interface PacketOptions<T> {
        unreliable?: boolean;
        rateLimit?: RateLimitConfig;
        validate?: (data: T, player: Player) => LuaTuple<[boolean, string?]>;
        maxPayloadBytes?: number;
        timestamp?: "frame" | "offset" | "full";
    }

    interface Packet<T> {
        /**
         * Server: target is required (single Player, array, Group, or sentinel).
         * Client: target is omitted; the second arg is ignored at runtime.
         * The signature unions both forms.
         */
        send(this: Packet<T>, data: T, target?: Target): void;
        on(this: Packet<T>, fn: (data: T, sender?: Player, timestamp?: number) => void): Connection;
        once(this: Packet<T>, fn: (data: T, sender?: Player, timestamp?: number) => void): Connection;
        wait(this: Packet<T>): LuaTuple<[T, Player?, number?]>;
        name(this: Packet<T>): string;
        stats(this: Packet<T>): PacketStats;
    }

    // ── Query ───────────────────────────────────────────────────────────

    interface QueryOptions<Req> {
        timeout?: number;
        rateLimit?: RateLimitConfig;
        validate?: (data: Req, player: Player) => LuaTuple<[boolean, string?]>;
    }

    interface Query<Req, Resp> {
        handle(
            this: Query<Req, Resp>,
            fn: (request: Req, player?: Player) => Resp | undefined,
        ): Connection;

        /** Client: yields until reply or timeout; nil on timeout. */
        request(this: Query<Req, Resp>, data: Req): Resp | undefined;
        /** Server, single-Player target. */
        request(this: Query<Req, Resp>, data: Req, target: Player): Resp | undefined;
        /** Server, multi-target (Group, array, all, except). */
        request(this: Query<Req, Resp>, data: Req, target: Target): Map<Player, Resp | undefined>;

        name(this: Query<Req, Resp>): string;
        stats(this: Query<Req, Resp>): PacketStats;
    }

    // ── Group ───────────────────────────────────────────────────────────

    interface Group extends Iterable<Player> {
        /** Returns true if membership changed (idempotent). */
        add(this: Group, player: Player): boolean;
        remove(this: Group, player: Player): boolean;
        has(this: Group, player: Player): boolean;
        count(this: Group): number;
        /** Clear members and free the name. */
        destroy(this: Group): void;
    }

    // ── Scope ───────────────────────────────────────────────────────────

    interface Scope {
        on<T>(
            this: Scope,
            source: Packet<T>,
            fn: (data: T, sender?: Player, timestamp?: number) => void,
        ): Connection;
        once<T>(
            this: Scope,
            source: Packet<T>,
            fn: (data: T, sender?: Player, timestamp?: number) => void,
        ): Connection;
        add(this: Scope, connection: Connection | RBXScriptConnection): void;
        destroy(this: Scope): void;
    }

    // ── Targets ─────────────────────────────────────────────────────────

    type Target = Player | Player[] | Group | AllTarget | ExceptTarget;

    /** Branded sentinel returned by `Lync.all`. */
    interface AllTarget {
        /** @hidden */ readonly _lyncKind: "all";
    }

    /** Branded sentinel returned by `Lync.except(...)`. */
    interface ExceptTarget {
        /** @hidden */ readonly _lyncKind: "except";
    }

    /** Branded sentinel exposed as `Lync.DROP`. Return from `onSend` to discard. */
    interface DropSentinel {
        /** @hidden */ readonly _lyncKind: "drop";
    }

    // ── Codec inference ─────────────────────────────────────────────────

    type InferCodec<C> = C extends Codec<infer T> ? T : never;

    type InferSchema<S extends Record<string, Codec<unknown>>> = {
        [K in keyof S]: InferCodec<S[K]>;
    };

    // ── Callable codec brands (function-call form for variants) ─────────

    interface StringCodec extends Codec<string> {
        /** Bounded variant; rejects on read if length exceeds maxLength. */
        (maxLength: number): Codec<string>;
    }

    interface Vec2Codec extends Codec<Vector2> {
        /** Quantized per-component variant. 2/4/8 bytes. */
        (min: number, max: number, precision: number): Codec<Vector2>;
    }

    interface Vec3Codec extends Codec<Vector3> {
        /** Quantized per-component variant. 3/6/12 bytes. */
        (min: number, max: number, precision: number): Codec<Vector3>;
    }

    interface CFrameCodec extends Codec<CFrame> {
        /** Smallest-three-quaternion variant. 16 bytes; ≤ 0.16° rotation error. */
        (): Codec<CFrame>;
    }

    // ── Bitfield schema ─────────────────────────────────────────────────

    type BitfieldField =
        | { type: "bool" }
        | { type: "uint"; width: number }
        | { type: "int"; width: number };

    // ── Configure ───────────────────────────────────────────────────────

    interface ConfigureOptions {
        channelMaxSize?: number;
        validationDepth?: number;
        poolSize?: number;
        bandwidthLimit?: { softLimit: number; maxStrikes: number };
        globalRateLimit?: { maxPerSecond: number };
        stats?: boolean;
    }

    // ── Registration debug shape ────────────────────────────────────────

    interface RegistrationInfo {
        name: string;
        id: number;
        kind: number;
        isUnreliable: boolean;
    }
}

interface LyncModule {
    // ── Lifecycle ───────────────────────────────────────────────────────

    configure(this: void, options: Lync.ConfigureOptions): void;
    start(this: void): void;
    isStarted(this: void): boolean;
    flush(this: void): void;
    flushRate(this: void, hz: number): void;
    /** Restore module state to post-require defaults. For tests / hot reload. */
    reset(this: void): void;

    // ── Definitions ─────────────────────────────────────────────────────

    packet<T>(
        this: void,
        name: string,
        codec: Lync.Codec<T>,
        options?: Lync.PacketOptions<T>,
    ): Lync.Packet<T>;

    query<Req, Resp>(
        this: void,
        name: string,
        requestCodec: Lync.Codec<Req>,
        responseCodec: Lync.Codec<Resp>,
        options?: Lync.QueryOptions<Req>,
    ): Lync.Query<Req, Resp>;

    group(this: void, name: string): Lync.Group;
    scope(this: void): Lync.Scope;

    // ── Targeting ───────────────────────────────────────────────────────

    readonly all: Lync.AllTarget;
    except(this: void, ...args: Array<Player | Lync.Group>): Lync.ExceptTarget;
    readonly DROP: Lync.DropSentinel;

    // ── Middleware ──────────────────────────────────────────────────────

    onSend(
        this: void,
        fn: (data: unknown, name: string, player?: Player) => unknown,
    ): Lync.Connection;
    onReceive(
        this: void,
        fn: (data: unknown, name: string, player?: Player) => unknown,
    ): Lync.Connection;
    onDrop(
        this: void,
        fn: (player: Player, reason: string, name: string, data?: unknown) => void,
    ): Lync.Connection;

    // ── Stats ───────────────────────────────────────────────────────────

    readonly stats: {
        /** Server-only; returns undefined on client or before stats=true. */
        player(this: void, player: Player): Lync.PlayerStats | undefined;
        reset(this: void): void;
    };

    // ── Debug ───────────────────────────────────────────────────────────

    readonly debug: {
        /** Reserved no-op for capture/replay tooling. */
        capture(this: void, label?: string): void;
        /** Reserved no-op for capture/replay tooling. */
        stop(this: void): void;
        /** Reserved no-op for capture/replay tooling. */
        dump(this: void): void;
        pending(this: void): number;
        registrations(this: void): ReadonlyArray<Lync.RegistrationInfo>;
    };

    // ── Number codecs ───────────────────────────────────────────────────

    int(this: void, min: number, max: number): Lync.Codec<number>;
    /**
     * Variable-length signed int via zigzag varint. 1 byte for values in
     * [-96, 95]; up to 5 bytes for full i32. Optional bounds gate input.
     */
    zint(this: void, min?: number, max?: number): Lync.Codec<number>;
    float(this: void, min: number, max: number, precision: number): Lync.Codec<number>;
    readonly f16: Lync.Codec<number>;
    readonly f32: Lync.Codec<number>;
    readonly f64: Lync.Codec<number>;
    readonly bool: Lync.Codec<boolean>;

    // ── Delta scalars (reliable transport only) ─────────────────────────

    /**
     * Integer that emits zigzag varint of (current - previous). Reliable
     * transport only; a dropped frame desyncs the receiver. Best for ints
     * mutating slowly across a wide range (saves vs fixed u16/u24/u32).
     */
    deltaInt(this: void, min: number, max: number): Lync.Codec<number>;
    /**
     * Quantized float with per-frame diff in integer wire space (no drift).
     * Same wire-size profile as deltaInt. Reliable transport only.
     */
    deltaFloat(
        this: void,
        min: number,
        max: number,
        precision: number,
    ): Lync.Codec<number>;
    /**
     * Quantized Vector3 with per-axis zigzag varint diffs. ~3 bytes for
     * unchanged, 3-15 bytes for typical motion vs 12 bytes baseline.
     * Reliable transport only.
     */
    deltaVec3(
        this: void,
        min: number,
        max: number,
        precision: number,
    ): Lync.Codec<Vector3>;
    /**
     * Quantized position + smallest-three quaternion rotation. 1 byte for
     * fully static; 4-7 bytes for position-only motion; up to 13 bytes
     * for full pose changes vs 24 bytes baseline. Reliable transport only.
     */
    deltaCFrame(
        this: void,
        posMin: number,
        posMax: number,
        posPrecision: number,
    ): Lync.Codec<CFrame>;

    // ── String & buffer ─────────────────────────────────────────────────

    readonly string: Lync.StringCodec;
    readonly buff: Lync.Codec<buffer>;

    // ── Vectors & spatial ───────────────────────────────────────────────

    readonly vec2: Lync.Vec2Codec;
    readonly vec3: Lync.Vec3Codec;
    readonly cframe: Lync.CFrameCodec;
    readonly ray: Lync.Codec<Ray>;
    readonly rect: Lync.Codec<Rect>;
    readonly region3: Lync.Codec<Region3>;
    readonly region3int16: Lync.Codec<Region3int16>;
    readonly vec2int16: Lync.Codec<Vector2int16>;
    readonly vec3int16: Lync.Codec<Vector3int16>;

    // ── Roblox types ────────────────────────────────────────────────────

    readonly color3: Lync.Codec<Color3>;
    readonly inst: Lync.Codec<Instance>;
    readonly udim: Lync.Codec<UDim>;
    readonly udim2: Lync.Codec<UDim2>;
    readonly numberRange: Lync.Codec<NumberRange>;
    readonly numberSequence: Lync.Codec<NumberSequence>;
    readonly colorSequence: Lync.Codec<ColorSequence>;

    // ── Composites ──────────────────────────────────────────────────────

    struct<S extends Record<string, Lync.Codec<unknown>>>(
        this: void,
        schema: S,
    ): Lync.Codec<Lync.InferSchema<S>>;

    /** Reliable transport only; rejected at definition time on `unreliable`. */
    deltaStruct<S extends Record<string, Lync.Codec<unknown>>>(
        this: void,
        schema: S,
    ): Lync.Codec<Lync.InferSchema<S>>;

    array<T>(this: void, element: Lync.Codec<T>, maxCount?: number): Lync.Codec<T[]>;
    /** Reliable transport only. */
    deltaArray<T>(this: void, element: Lync.Codec<T>, maxCount?: number): Lync.Codec<T[]>;

    map<K, V>(
        this: void,
        keyCodec: Lync.Codec<K>,
        valueCodec: Lync.Codec<V>,
        maxCount?: number,
    ): Lync.Codec<Map<K, V>>;
    /** Reliable transport only. */
    deltaMap<K, V>(
        this: void,
        keyCodec: Lync.Codec<K>,
        valueCodec: Lync.Codec<V>,
        maxCount?: number,
    ): Lync.Codec<Map<K, V>>;

    optional<T>(this: void, codec: Lync.Codec<T>): Lync.Codec<T | undefined>;

    tuple<T extends Lync.Codec<unknown>[]>(
        this: void,
        ...codecs: T
    ): Lync.Codec<{ [K in keyof T]: Lync.InferCodec<T[K]> }>;

    /**
     * Discriminated union with a string tag field. Up to 256 variants;
     * each variant is a struct codec keyed by name.
     */
    tagged<Tag extends string, V extends Record<string, Lync.Codec<unknown>>>(
        this: void,
        tagField: Tag,
        variants: V,
    ): Lync.Codec<
        { [K in keyof V & string]: { [F in Tag]: K } & Lync.InferCodec<V[K]> }[keyof V & string]
    >;

    // ── Meta ────────────────────────────────────────────────────────────

    enum<T extends string[]>(this: void, ...values: T): Lync.Codec<T[number]>;

    bitfield(
        this: void,
        schema: Record<string, Lync.BitfieldField>,
    ): Lync.Codec<Record<string, boolean | number>>;

    custom<T>(
        this: void,
        size: number,
        write: (b: buffer, offset: number, value: T) => void,
        read: (b: buffer, offset: number) => T,
        typeCheck?: string,
    ): Lync.Codec<T>;

    /** 0-byte codec; reads `undefined`. Use for fire-and-forget signals. */
    readonly nothing: Lync.Codec<undefined>;
    /** Bypasses serialization through the channel sidecar. Pair with `validate`. */
    readonly unknown: Lync.Codec<unknown>;
    /** Self-describing; nil/bool/numbers/strings/buffers/Roblox datatypes. */
    readonly auto: Lync.Codec<unknown>;
}

declare const Lync: LyncModule;
export = Lync;
