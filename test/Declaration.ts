import Lync from "../index";

const Codec = Lync.struct({
    name: Lync.str(1, 20),
    score: Lync.int(0, 1_000_000).monotonic(),
    pos: Lync.vec3(Lync.quant(-512, 512, 0.1)).newest(10),
    team: Lync.enum(["red", "blue"] as const),
    flags: Lync.bitfield(["alive", "stunned"] as const),
    tag: Lync.optional(Lync.str(0, 8)),
});

type Fighter = Lync.Infer<typeof Codec>;

const Net = Lync.define("arena", {
    Fighters: Lync.replicate(Codec).keyBy("team"),
    Strike: Lync.packet(Lync.vec3()).unreliable(),
    Aim: Lync.packet(Lync.rotation.quat(0.2)).newest(20).timestamped(),
    Sell: Lync.query(
        Lync.struct({ item: Lync.str(1, 8) }),
        Lync.struct({ earned: Lync.int(0, 100) }),
    ),
});

// --- inference ------------------------------------------------------------
const f: Fighter = { name: "a", score: 0, pos: new Vector3(), team: "red", flags: { alive: true, stunned: false }, };
const _team: "red" | "blue" = f.team;
const _alive: boolean = f.flags.alive;

// --- sets -----------------------------------------------------------------
Net.Fighters.add(1, f);
Net.Fighters.update(1, { score: 5 });
Net.Fighters.update(1, { tag: Lync.none });
Net.Fighters.remove(1);
Net.Fighters.clear();
Net.Fighters.audience("red", Lync.all);
const got: Fighter | undefined = Net.Fighters.get(1);
const n: number = Net.Fighters.size();
Net.Fighters.onAdded((id, record) => print(id, record.name));
Net.Fighters.onChanged((id, record, old) => print(record.score, old?.score));
Net.Fighters.onRemoved((id, cause) => { const c: Lync.Cause = cause; });
for (const [id, record] of Net.Fighters) { print(id, record.name); }

// --- packets --------------------------------------------------------------
Net.Strike.fireServer(new Vector3());
Net.Strike.fireClient(Lync.all, new Vector3());
Net.Strike.fireClient(Lync.except(Lync.group()), new Vector3());
const conn: Lync.Connection = Net.Strike.onServer((v, player, sent) => print(v.X, player.UserId, sent));
conn.disconnect();

// --- queries --------------------------------------------------------------
Net.Sell.onServer((req, player) => ({ earned: 1 }));
const [ok, res, data] = Net.Sell.request({ item: "sword" });
if (ok) { const e: number = res.earned; }
Net.Sell.request(undefined as unknown as Player, { item: "x" }, (...r) => {
    if (r[0]) { const e: number = r[1].earned; } else { const c: Lync.OutcomeCode = r[1]; }
}, 5);

// --- lifecycle, log, stats ------------------------------------------------
Lync.start();
Lync.flush();
Lync.flush(4096);
Lync.flush("arena", 4096);
Lync.close();
Lync.onLog((kind, message, d) => print(kind, message, d.file, d.line, d.player));
Lync.console.disconnect();
const s: Lync.Stats = Lync.stats("arena");
const rate: number = s.sentBytes;
const per = s.definitions.get("Strike");

// --- codecs ---------------------------------------------------------------
// Annotated rather than called. Calling one proves the name is there, and the declaration is a
// promise about what comes back, so a constructor answering the wrong codec has to fail here.
const _bool: Lync.Codec<boolean> = Lync.bool();
const _f32: Lync.Codec<number> = Lync.f32();
const _f64: Lync.Codec<number> = Lync.f64();
const _vlq: Lync.Codec<number> = Lync.vlq();
const _vli: Lync.Codec<number> = Lync.vli();
const _angle: Lync.Codec<number> = Lync.angle(1);
const _alphanum: Lync.Codec<string> = Lync.str.alphanum(1, 4);
const _hex: Lync.Codec<string> = Lync.str.hex(2, 2);
const _bytes: Lync.Codec<buffer> = Lync.buffer(0, 64);
const _array: Lync.Codec<boolean[]> = Lync.array(Lync.bool(), 0, 4);
const _map: Lync.Codec<Map<string, boolean>> = Lync.map(Lync.str(1, 2), Lync.bool(), 0, 4);
const _vec2: Lync.Codec<Vector2> = Lync.vec2();
const _cframe: Lync.Codec<CFrame> = Lync.cframe(Lync.vec3(), Lync.rotation.none());
const _packed: Lync.Codec<Color3> = Lync.color3.rgb565();
const _palette: Lync.Codec<Color3> = Lync.color3.palette([]);
const _inst: Lync.Codec<Player | undefined> = Lync.inst<Player>();
const _validated: Lync.Codec<number> = Lync.int(0, 1).validate((v, ctx) =>
    ctx.player ? undefined : "no player",
);
const _lifted: Lync.Codec<string> = Lync.int(0, 1).as((v) => `${v}`, (u) => tonumber(u)!);

const Tagged = Lync.tagged("kind", {
    a: Lync.struct({ x: Lync.bool() }),
    b: Lync.struct({ y: Lync.bool() }),
});
const _variant: Lync.Infer<typeof Tagged> = { kind: "a", x: true };

/*
 * Both directions. An annotation is satisfied by anything assignable and a codec is covariant in
 * the value it carries, so a constructor that dropped an optional still passes one asking for it.
 *
 * Read off the call and never off an annotated binding, since an annotation pins the type whatever
 * came back and a check against one asks nothing at all.
 */
type Exact<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false;

const _instCall = Lync.inst<Player>();
const _instIsOptional: Exact<Lync.Infer<typeof _instCall>, Player | undefined> = true;

const _optionalCall = Lync.optional(Lync.str(0, 8));
const _optionalIsOptional: Exact<Lync.Infer<typeof _optionalCall>, string | undefined> = true;

const _enumCall = Lync.enum(["red", "blue"] as const);
const _enumIsUnion: Exact<Lync.Infer<typeof _enumCall>, "red" | "blue"> = true;

// --- rejections ------------------------------------------------------------
// Each line must fail to compile. @ts-expect-error fails the build if one starts passing.

const Plain = Lync.replicate(Codec);
const Keyed = Lync.replicate(Codec).keyBy("team");

// @ts-expect-error audience on an unkeyed set
Plain.audience("red", Lync.all);
// @ts-expect-error a key outside the field's type
Keyed.audience(1, Lync.all);
// @ts-expect-error the clear sentinel on a required field
Keyed.update(1, { score: Lync.none });
// @ts-expect-error a field the record does not declare that type for
Keyed.update(1, { score: "high" });
// @ts-expect-error keyBy an absent field
Lync.replicate(Codec).keyBy("nope");
// @ts-expect-error a set marker on a string codec
Lync.str(1, 2).monotonic();
// @ts-expect-error a payload the packet codec rejects
Net.Strike.fireServer(1);
// @ts-expect-error a flush budget that is not a number
Lync.flush("arena", "big");
// @ts-expect-error counters are numbers
const _bad: string = Lync.stats("arena").flushes;
