/// <reference types="@rbxts/types" />

declare namespace Lync {
    /** Opaque codec brand. `_nominal_codec` never exists at runtime. */
    interface Codec<T> {
        /** @hidden */ readonly _nominal_codec: T;
        /** Runs on decode. Return a reason to reject or nil to accept. The first reason wins. */
        validate(this: Codec<T>, check: (value: T, context: ValidateContext) => string | undefined): Codec<T>;
        /** Set fields only. The field never decreases, and an update that would lower it throws. */
        monotonic(this: Codec<number>): Codec<number>;
        /** Set fields only: lossy latest-wins replication, rate-capped when hz is given. */
        newest(this: Codec<T>, hz?: number): Codec<T>;
        /** Domain transform: `to` lifts after decode, `from` lowers before encode. */
        as<U>(this: Codec<T>, to: (value: T) => U, from: (value: U) => T): Codec<U>;
    }

    /** Reused between decodes, so copy anything kept. */
    interface ValidateContext {
        readonly player?: Player;
        readonly now: number;
        readonly last?: number;
    }

    interface Connection {
        readonly connected: boolean;
        disconnect(this: Connection): void;
    }

    /** @hidden */ interface None {
        readonly _nominal_none: never;
    }
    /** @hidden */ interface All {
        readonly _nominal_all: never;
    }
    /** @hidden */ interface Except {
        readonly _nominal_except: never;
    }

    type Recipient = All | Player | ReadonlyArray<Player> | Group | Except;

    type LogKind = "warn" | "error" | "debug";
    type Cause = "removed" | "cleared";
    type OutcomeCode = "timeout" | "unanswered" | "leave" | "shutdown";

    interface OutcomeData {
        readonly definition: string;
        readonly elapsed?: number;
    }

    interface LogData {
        readonly [key: string]: unknown;
        readonly file: string;
        readonly line: number;
        readonly player?: Player;
        readonly definition?: string;
    }

    interface DefinitionStats {
        readonly sent: number;
        readonly sentBytes: number;
        readonly received: number;
        readonly receivedBytes: number;
        readonly drops: number;
    }

    interface Stats {
        readonly flushes: number;
        readonly sentBytes: number;
        readonly receivedBytes: number;
        readonly drops: number;
        readonly definitions: ReadonlyMap<string, DefinitionStats>;
    }

    interface Packet<T> {
        /** Declaration: lossy, unordered, every fire still sent. */
        unreliable(this: Packet<T>): Packet<T>;
        /** Declaration: lossy latest-wins, rate-capped when hz is given. */
        newest(this: Packet<T>, hz?: number): Packet<T>;
        /** Declaration: stamps every fire with its flush's shared send instant. */
        timestamped(this: Packet<T>): Packet<T>;
        fireServer(this: Packet<T>, value: T): void;
        fireClient(this: Packet<T>, recipient: Recipient, value: T): void;
        /** `sent` is the fire's instant, and arrives only where the packet declared a stamp. */
        onServer(this: Packet<T>, fn: (value: T, player: Player, sent?: number) => void): Connection;
        /** `sent` is the fire's instant, and arrives only where the packet declared a stamp. */
        onClient(this: Packet<T>, fn: (value: T, sent?: number) => void): Connection;
        describe(this: Packet<T>): string;
    }

    /** The completion triple: `(true, reply)` or `(false, code, data)`, never a throw. */
    type Outcome<R> = (...result: [true, R] | [false, OutcomeCode, OutcomeData]) => void;

    interface Query<Q, R> {
        /** The one responder for client requests. What it returns is the reply. Before start only. */
        onServer(this: Query<Q, R>, fn: (value: Q, player: Player) => R): void;
        /** The one responder for server requests. Before start only. */
        onClient(this: Query<Q, R>, fn: (value: Q) => R): void;
        /** Server form. Never yields, and `complete` receives the outcome exactly once. */
        request(
            this: Query<Q, R>,
            client: Player,
            value: Q,
            complete: Outcome<R>,
            timeout?: number,
        ): void;
        /** Client form: yields until the reply or an outcome code. No ending throws, and it never hangs. */
        request(
            this: Query<Q, R>,
            value: Q,
            timeout?: number,
        ): LuaTuple<[true, R] | [false, OutcomeCode, OutcomeData]>;
        describe(this: Query<Q, R>): string;
    }

    /** `Lync.none` clears an optional field. A required field rejects it at the type level. */
    type Update<T> = {
        [K in keyof T]?: undefined extends T[K] ? T[K] | None : T[K];
    };

    type KeyableField<T> = {
        [K in keyof T]: T[K] extends boolean | number | string ? K & string : never;
    }[keyof T];

    interface Set<T, K = never> extends Iterable<LuaTuple<[number, T]>> {
        /** Declaration: partitions records by the field's value. Unkeyed sets have no audiences. */
        keyBy<F extends KeyableField<T>>(this: Set<T, never>, field: F): Set<T, T[F & keyof T]>;
        /** On first sight, which is an add, a late join, or a record coming into view. */
        onAdded(this: Set<T, K>, fn: (id: number, record: T) => void): Connection;
        onChanged(this: Set<T, K>, fn: (id: number, record: T, old?: T) => void): Connection;
        onRemoved(this: Set<T, K>, fn: (id: number, cause: Cause) => void): Connection;
        /** Server only. Throws on a live id. */
        add(this: Set<T, K>, id: number, record: T): void;
        /** Server only. Throws on an absent id. */
        update(this: Set<T, K>, id: number, fields: Update<T>): void;
        /** Server only. Throws on an absent id. */
        remove(this: Set<T, K>, id: number): void;
        /** Server only. Empties the whole set. */
        clear(this: Set<T, K>): void;
        /** Server only, keyed sets only. A later assignment replaces the earlier one. */
        audience(this: Set<T, K>, key: K, recipient: Recipient): void;
        /** The live record or nil. This is the library's own storage, so read it and never write. */
        get(this: Set<T, K>, id: number): T | undefined;
        size(this: Set<T, K>): number;
        describe(this: Set<T, K>): string;
    }

    interface Group extends Iterable<Player> {
        add(this: Group, player: Player): void;
        remove(this: Group, player: Player): void;
        has(this: Group, player: Player): boolean;
        size(this: Group): number;
        /** Empties the group. Any later use throws. */
        destroy(this: Group): void;
    }

    interface Str {
        (this: void, min: number, max: number): Codec<string>;
        /** Every character drawn from the symbol set. The smaller the set, the fewer the bits. */
        alphabet(this: void, symbols: string, min: number, max: number): Codec<string>;
        alphanum(this: void, min: number, max: number): Codec<string>;
        base32(this: void, min: number, max: number): Codec<string>;
        base64(this: void, min: number, max: number): Codec<string>;
        digits(this: void, min: number, max: number): Codec<string>;
        hex(this: void, min: number, max: number): Codec<string>;
    }

    interface Vec3 {
        (this: void, component?: Codec<number>): Codec<Vector3>;
        /** A direction at the angular precision. Any nonzero vector normalizes at encode. */
        unit(this: void, precision: number): Codec<Vector3>;
        /** A direction at the implied precision and a quantized magnitude. */
        bounded(this: void, max: number, step: number): Codec<Vector3>;
    }

    /** Zero, one, two, or three degrees of freedom, in that order. */
    interface Rotation {
        none(this: void): Codec<CFrame>;
        axis(this: void, axis: Vector3, precision: number): Codec<CFrame>;
        direction(this: void, precision: number): Codec<CFrame>;
        quat(this: void, precision: number): Codec<CFrame>;
    }

    interface Color3Codec {
        (this: void): Codec<Color3>;
        rgb565(this: void): Codec<Color3>;
        palette(this: void, colors: ReadonlyArray<Color3>): Codec<Color3>;
    }

    type Infer<C> = C extends Codec<infer T> ? T : never;

    /** @hidden */ type Flat<T> = { [K in keyof T]: T[K] };

    /** A field whose codec is `optional` is omittable, as a Luau `{ tag: string? }` is. */
    type Schema<S extends Record<string, Codec<unknown>>> = Flat<
        { [K in keyof S as undefined extends Infer<S[K]> ? never : K]: Infer<S[K]> } & {
            [K in keyof S as undefined extends Infer<S[K]> ? K : never]?: Infer<S[K]>;
        }
    >;
}

interface LyncModule {
    /** Opens a namespace. The returned table is pure data, required by both machines. */
    define<T extends Record<string, Lync.Packet<unknown> | Lync.Query<unknown, unknown> | Lync.Set<unknown, unknown>>>(
        this: void,
        name: string,
        defs: T,
    ): Readonly<T>;
    /** Seals, compiles, opens transports, runs the handshake. Exactly once per machine. */
    start(this: void): void;
    /** Sends everything buffered. Nothing goes out without it, and an empty flush is free. */
    flush(this: void): void;
    /** The byte budget caps replicated state only. Packets and requests always send in full. */
    flush(this: void, maxBytes: number): void;
    /** One namespace, on a cadence of its own. */
    flush(this: void, name: string, maxBytes?: number): void;
    /** One final flush. Outstanding requests resolve as shutdown and the transports go. */
    close(this: void): void;

    packet<T>(this: void, codec: Lync.Codec<T>): Lync.Packet<T>;
    query<Q, R>(this: void, request: Lync.Codec<Q>, response: Lync.Codec<R>): Lync.Query<Q, R>;
    replicate<T extends object>(this: void, struct: Lync.Codec<T>): Lync.Set<T>;
    group(this: void): Lync.Group;

    readonly all: Lync.All;
    except(this: void, target: Player | ReadonlyArray<Player> | Lync.Group): Lync.Except;
    /** The clear sentinel: an update writes it to empty an optional field. */
    readonly none: Lync.None;

    onLog(this: void, fn: (kind: Lync.LogKind, message: string, data: Lync.LogData) => void): Lync.Connection;
    /** The default printer. Disconnect it to format records yourself. */
    readonly console: Lync.Connection;
    /** A frozen snapshot of monotonic counters, so any two of them diff into exact rates. */
    stats(this: void, name: string): Lync.Stats;

    /** No payload at all, for a call whose happening is the whole of what it says. */
    empty(this: void): Lync.Codec<undefined>;
    bool(this: void): Lync.Codec<boolean>;
    int(this: void, min: number, max: number): Lync.Codec<number>;
    quant(this: void, min: number, max: number, step: number): Lync.Codec<number>;
    /** Degrees, cyclic, wrapping at a whole turn. */
    angle(this: void, precision: number): Lync.Codec<number>;
    f32(this: void): Lync.Codec<number>;
    f64(this: void): Lync.Codec<number>;
    /** Unsigned integer exact to 2^53. */
    vlq(this: void): Lync.Codec<number>;
    /** Signed integer exact to 2^53. */
    vli(this: void): Lync.Codec<number>;
    readonly str: Lync.Str;
    buffer(this: void, min: number, max: number): Lync.Codec<buffer>;

    struct<S extends Record<string, Lync.Codec<unknown>>>(
        this: void,
        fields: S,
    ): Lync.Codec<Lync.Schema<S>>;
    array<T>(this: void, element: Lync.Codec<T>, min: number, max: number): Lync.Codec<T[]>;
    map<K, V>(
        this: void,
        key: Lync.Codec<K>,
        value: Lync.Codec<V>,
        min: number,
        max: number,
    ): Lync.Codec<Map<K, V>>;
    optional<T>(this: void, inner: Lync.Codec<T>): Lync.Codec<T | undefined>;
    tagged<F extends string, V extends Record<string, Lync.Codec<object>>>(
        this: void,
        field: F,
        variants: V,
    ): Lync.Codec<
        { [K in keyof V & string]: { [P in F]: K } & Lync.Infer<V[K]> }[keyof V & string]
    >;
    enum<const T extends readonly string[]>(this: void, names: T): Lync.Codec<T[number]>;
    bitfield<const T extends readonly string[]>(
        this: void,
        names: T,
    ): Lync.Codec<{ [K in T[number]]: boolean }>;
    /** A value the schema does not describe. Costs a tag per part and skips every packing. */
    unknown(this: void, maxBytes: number): Lync.Codec<unknown>;

    vec2(this: void, component?: Lync.Codec<number>): Lync.Codec<Vector2>;
    readonly vec3: Lync.Vec3;
    cframe(this: void, position: Lync.Codec<Vector3>, rotation: Lync.Codec<CFrame>): Lync.Codec<CFrame>;
    readonly rotation: Lync.Rotation;
    readonly color3: Lync.Color3Codec;
    /** Decodes to the instance or nil when the receiver cannot see it. */
    inst<T extends Instance = Instance>(this: void, className?: string): Lync.Codec<T | undefined>;
}

declare const Lync: LyncModule;
export = Lync;
