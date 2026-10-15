# Brief: the failed Lync v5 attempt ("two")

Sources read in full: docs v5-goals, v5-api, v5-wire, v5-research, v5-security, v5-failures, v5-testing,
v5-roblox-ts; probes ApiTypes.luau, Determinism.luau + Windows output; attempt tree `spec/*.md` (all six),
`.darklua/*.json5`, project jsons, `rokit.toml`, `.luaurc`, `packaging/`, `definitions/` pins. `harness/`
and `scripts/` were read through their module header docs plus `run.luau` and `test/Boot.server.luau`.
Labels: **[S]** the attempt says it; **[V]** the attempt says it checked it by running something;
**[I]** my inference.

**Headline fact [V, counted]:** the attempt tree has **no `src/` and no `bench/`**. It has ~10.7k lines of
`harness/`, ~8.3k lines of `scripts/` (Lute tooling), one `test/Boot.server.luau`, and **~670 numbered
spec claims** (A 207, W 208, H 132, F 93, L 31). Not one line of codec, wire or runtime code was written.

---

## 1. Goals the attempt set (deduplicated)

1. Rewrite with no backward compatibility: API, wire, layout and tooling all change. [S]
2. Smallest wire inside a CPU budget; every encoding choice justified by measured bytes and CPU. [S]
3. Accuracy declared per field (exact / tolerance / eventually exact); exact by default. [S]
4. Lossy values are fine, but codec state both sides mirror must be bit-identical (integer-only). [S]
5. Modern Luau only: `--!strict`, new solver, `const`, type functions, `read` fields, `buffer`/`vector`. [S]
6. Never lower code quality for a tool, host, the old solver or roblox-ts. [S]
7. One failure model: every situation has exactly one channel, a message mold and a test. [S]
8. Errors point at the user's line; user callbacks never run on Lync's stack. [S]
9. Silent in normal operation; hostile input never floods Output. [S]
10. Provable coverage: every spec claim has a test (claim ids), line coverage gated. [S]
11. Trustworthy benchmarks: real statistics, per-host baselines, regression gate, bytes as first-class metric. [S]
12. Hardened against exploiters: bounded CPU/memory per inbound frame, per-player limits, fuzzing as a gate. [S]
13. Docs cannot drift: generated/checked from source and spec; every doc example runs. [S]
14. "A joy to use": exact types with no annotations, no boilerplate traps (no `start`, no `flush` wiring). [S]
15. Types are sound (never wider/narrower than what the wire checks) and follow values (nothing spelled twice). [S]
16. roblox-ts in scope with first-class declarations, but costing the Luau surface nothing. [S]
17. Tests and benches run in Roblox Studio only; CI does not run the suite (decision 1). [S]
18. Ship four channels: rbxm model, single-file bundle, Wally, npm. Build only with darklua features. [S]

## 2. Proposed API and syntax

Schema (shared module) [S, v5-api §1]:
```luau
return Lync.namespace({
	chat = Lync.event(Lync.string(200)),
	strike = Lync.event({ target = Lync.integer(0, 255), position = Lync.vector3(-512, 512, 0.1) })
		:unreliable():timestamped(),
	outcome = Lync.event(Lync.union({ hit = { target = Lync.integer(0, 255) },
	                                  miss = { distance = Lync.number(0, 100, 0.1) } })),
	sell = Lync.request(Lync.oneOf({ sword = true, shield = true }), Lync.integer(0, 100_000)),
	fighters = Lync.collection({
		team      = Lync.oneOf({ red = true, blue = true }):partition(),
		health    = Lync.integer(0, 100),
		position  = Lync.vector3(-512, 512, 0.1):latest(20),
		title     = Lync.string(16):optional(),
		inventory = Lync.array(Lync.string(16), 32),
	}),
})
```
Use [S]:
```luau
local Net = Lync.server(require(ReplicatedStorage.Net))
Net.chat:limit(5)
Net.chat:validate(function(text, player) return if string.find(text, "%S") then nil else "blank" end)
Net.chat:connect(function(text, player) Net.chat:fire(Lync.all, `{player.Name}: {text}`) end)
Net.sell:handle(function(item, player) return PRICES[item] end)
Net.fighters[player.UserId] = { team = "red", health = 100, position = Vector3.zero, inventory = {} }
Net.fighters:update(player.UserId, { health = 90 })
Net.fighters:show("red", redTeam)
-- client
local sold = Net.sell:invoke("sword"); if sold.ok then print(sold.value) end
Net.fighters.added:connect(function(id, fighter) end)
```
Surface rules [S]: one schema, two views (`Lync.server`/`Lync.client`), other side's calls are type errors;
one verb per action (`fire`/`connect`/`invoke`/`handle`); leaf codecs are values, calling refines
(`Lync.integer` vs `Lync.integer(0,255)`); params are limits (`maxBytes`, `maxCount`) or accuracy
`(min, max, step)` with step in the value's unit; payload-first listener args, then player, then `sentAt`;
`Result<T> = {ok=true,value} | {ok=false, reason="Timeout"|"Unanswered"|"Left"|"Shutdown"}`; policy
(`validate`, `limit`) lives on the server view only; `Lync.instance.Player`, `Lync.enum.Material` are
generated tables from a pinned API dump; `Lync.convert(wire, {decode, encode})`; `Lync.none`,
`Lync.all`, `Lync.except`, `Lync.group()`, `Lync.observe`, `Lync.metrics`, `Lync.check`, `Lync.stop`,
`Lync.configure({flush="Manual"|interval|console|profile|columns})`, `Lync.flush(ns?, budget?)`.
No start call, no flush wiring; Lync starts on first view use. Collections: `c[id] = rec`, `c[id] = nil`,
`:update`, `:clear`, `:show(key, recipients)`, `:hide(key)`, `#c`, `for id, r in c`, signals
`added/changed/removed`. The spec later added a seams record `Lync.server(ns, {transport, clock, roster})`.

**Elegant [I]:** side views with type-level side separation; schema = plain tables, no `struct()` wrapper;
`Result` instead of throwing; collection read/write as plain indexing; server-only policy; the verb table
mapping onto Roblox vocabulary; "forgotten `show` hides rather than leaks"; `removed` hides delete-vs-hide.

**Clumsy / inconsistent [I unless marked]:**
- `oneOf({ sword = true, shield = true })` and `flags({ jump = true })`: the attempt's own self-review
  (goals table item 5) calls the set literal "clunkier than anything a user would write unprompted", then
  ships it anyway because it is the only form Luau types exactly [S].
- `latest` means two different things: an event delivery mode (`event:latest(rate)`) and a collection field
  marker (`codec:latest(rate)`); needs a type-function trap to reject it in events.
- Positional `sentAt` shifts by side: server `(value, player, sentAt)`, client `(value, sentAt)`.
- `limit(perSecond)` in v5-api vs `limit(rate, burst?)` in the spec; `update` patches are untyped in the
  probe (`{ [string]: unknown }`), contradicting "no annotations / patches inferred".
- `Lync.convert` in the probe needed annotations (`decode = function(wire): UDim`, `encode = function(size: UDim)`).
- Namespace identity = the calling module's full name (via `debug.info`), "no explicit-name form" [S]:
  magic; renaming/moving the module or bundling changes the protocol key.
- Union discriminant hard-coded to `kind`; four event types (`Event`, `TimedEvent`, `LossyEvent`,
  `TimedLossyEvent`) because Luau aliases cannot recurse with different params; doubled again per side.
- Collections are metatable proxies typed as plain tables (a deliberate type lie so the checker validates
  writes), which in turn forced the roblox-ts side into frozen adapter wrappers, weak-keyed caches and a
  group swap at three call sites.
- Spec grew to ~36 `Lync` members and three seams with Roblox-shaped signals (`:Connect`/`:Once`).
- v5-security adds `intent`, `budget`, `use(...)`, `:inbound/:outbound/:inboundFrame`, `suspect`,
  `escalate`, `trap`, `namespace(defs, { forgery = "standard" })` — never folded into the spec.

## 3. Wire format and compression ideas

Evidence base [S]: Studio checks only for extremes; everything else "offline" with CPython 3.14 libzstd
level 3 as a stand-in and synthetic Monte Carlo workloads. "No Studio instance was connected" during wire design.

Decisions D-1..D-11 [S]:
- One **dense LSB-first bit stream** per frame; only string/buffer bytes byte-aligned (so zstd sees text).
  First 3 bits = padding count P. No length prefix on blocks.
- **Schema-aware coding before zstd**, no own entropy coder: Exp-Golomb EG-k, zigzag, a 4-bit "class code"
  for unbounded ints (widths {0,1,2,3,4,5,6,8,10,12,16,20,24,32,40,53}; costs 0→4 b, 1→6, 100→13,
  1000→15, 50 000→21, 1e9→37), change masks.
- **Column coder**: for arrays/ADD/UPDATE, a field's values are written as a column with a 2-bit mode
  PACKED/RUNS/DELTA/STATE + 4-bit k; encoder tries all modes × k=0..15, never >2 bits worse than PACKED.
- **Three remotes per copy**, one-char names `r` (reliable), `u` (unreliable), `h` (handshake); one call per
  recipient per lane per flush; block header = same-namespace bit, else 4-bit ns slot, then def id in
  `bits(n-1)`; ids by sorted names; one id table both lanes so oversize unreliable can **demote** to reliable.
- Caps: reliable call 16 384 B (provisional), single message up to 1 MiB alone; unreliable frame
  `985 - 6*I` B (I = instance args), ≤64 instances/call, instances as variadic args after the buffer.
- Codecs: boolean 1 b; `integer(min,max)` = bits(span); bare `number` 2-bit form (int class code /
  exact float32 / f64 / NaN); `number(min,max,step)` index; `vector3` bare = 3×f32; `direction(step)`
  octahedral fold, b bits per axis (8 b → 0.93° worst, 9 b → 0.47°); `rotation(step)` smallest-three
  quaternion (2 b index + 3×b; 8 b → 0.96°); bare rotation axis-aligned flag + 5-bit index of 24;
  `color3(step)`; `string` length then align + bytes; enum index into pinned sorted item values; record =
  fields in ascending name order; optional = presence bit; union = variant index; map = sorted key array.
  Bare `angle`/`direction`/`rotation` cost up to 66/96/99 bits (axis-aligned rotation 6).
- Events: run of messages with EG-0 count; timestamped = 16-bit ms stamp of `GetServerTimeNow` once per
  block + EG-2 offsets (works within ±32 s skew). Latest events: 8-bit sequence, newest wins.
- Collections: server-assigned slots per partition, SlotSets (EG-k gaps), ADD/UPDATE/REMOVE/CLEAR/LATEST,
  field mask + coverage bit, STATE deltas against last reliable state, **no acks** (reliable order makes
  receiver state equal sender's), sections bit-identical for all viewers (encode once), "settle": a latest
  field idle 0.5 s is resent reliably. Coalescing algebra for consecutive writes (insert+remove = nothing).
- Requests: 12-bit ids mod 4096, quarantine of timed-out ids, response = id + outcome bit + reply.
- Handshake: HELLO (version, ns name, FNV-1a32 hash) → VERDICT (status 0..4, slot, server hash, and on
  mismatch per-definition hash pairs so the server can **name differing definitions**). Schema never sent.
- Golden: `chat("hi")` → 4 bytes `08 01 68 69`.

Offline numbers [S]: dense vs record-aligned vs byte-wide frames: snapshot K=64 584/640/710 B; events
K=200 450/528/571; delta stream 711/736/821; tiles with runs 365/234/234 (aligned wins there, but RUNS
column gives 38 B vs 90). Column modes beat packed+zstd 1.2–2.6× (sorted ids 142 vs 352; height walk 121
vs 319). Delta (k=2) vector3 update 42 → 16.0/13.6/10.8 bits at 10/20/60 Hz. Baseline-delta for latest
fields would save 46–64% (deferred to M-6). Anti-forgery trailer +4 B/client frame (~29% on a tiny frame).

Measurement plan M-1..M-9 (all unrun except the extremes) [S]. The "ruler": append 1100 random bytes,
fire on `u`, read "Payload went over by: N bytes" to get a frame's compressed size.

## 4. Typing findings (ApiTypes.luau, luau-lsp 1.70.1 / Luau 0.740 / new solver)

What the probe actually is [V]: a types-only prototype (`local Lync = ({} :: any) :: {...}`), no runtime.
The doc claims its only diagnostics are the 11 deliberate mistakes.

Core mechanism [V]: codecs carry a phantom `read _value: T`; markers are phantom `_latest: true`,
`_partition: true`; definitions carry phantom `_server`/`_client` view types. Type functions:
```luau
type function InferSchema(schema)            -- table of codecs -> record type, recursive
  if node:is("intersection") then            -- callable codecs are Codec<T> & ((...) -> Codec<T>)
    for _, part in node:components() do ... part:readproperty(types.singleton("_value")) ...
  local record = types.newtable(); for name, p in node:properties() do record:setproperty(name, infer(p.read or p.write)) end
type function MessageSchema(schema)  -- error("latest marks a collection field; ...") surfaces at call site
type function UnionSchema(variants)  -- record:setproperty(types.singleton("kind"), name); types.unionof(...)
type function ViewOf(namespace, side) -- key = `_{side:value()}`; view:setreadproperty(name, sideView)
oneOf: <T>(names: T) -> Codec<keyof<T>>
```
Facts table (v5-api §9, v5-research §6, goals) [V unless noted]:
- A type function turns a plain table of codecs into a record type, nested tables included → no `struct`.
- A type function maps each namespace entry to a per-side view → wrong-side calls are type errors.
- **Literal arguments widen**: `f("1v1","2v2")` and `f({"1v1","2v2"})` → `string`; numbers → `number`.
  **Table keys keep literals**: `f({ ["1v1"]=true, ["2v2"]=true })` with `keyof<T>` → exactly
  `"1v1" | "2v2"`, rejects `"3v3"`. Explicit instantiation `f<<"1v1"|"2v2">>("1v1","2v2")` is exact but
  spelled twice. Enum items as args → `Enum.Material`. A whole Enum (`oneOf(Enum.Material)`) is **not
  inferable**: structural inference gives `unknown`, and type functions cannot read extern types
  ("expected self to be a table, got extern"). Number literal sets: no clean path [S].
- **A generic method on codec types makes type functions fail on every codec** → codec methods must be
  non-generic; `convert` became a free function.
- **An alias cannot refer to itself with different parameters** → each modifier/event state needs its own
  named type (state-machine explosion: Event/TimedEvent/LossyEvent/TimedLossyEvent × Server/Client).
- `error()` inside a type function is reported at the user's call site → custom type error messages.
- **A function passed as an argument has its parameters inferred; one assigned to a property does not
  (params become generics)** → `handle(fn)` / `connect(fn)` / `validate(fn)`, never `x.handler = fn`.
- **629 Enum overloads exceed Luau's complexity limit**; a generated table of 629 Enum codecs checks in
  about a second → `Lync.enum`, `Lync.instance` are generated tables. [S; the probe itself has 2 enums
  and 3 classes, so the scale claim is not in the file I read.]
- **A callable value intersected with a table hides missing-key errors** → generated tables are plain
  tables. [I: yet every leaf codec in the probe is exactly such an intersection, so typos on refined codec
  members may go unreported.]
- **Writes through a `setmetatable<...>` indexer are not checked**; a plain table type with an indexer is;
  a `read` indexer rejects writes → collections typed as plain tables, client one with `read [number]: R?`.
- One type function can call another (MessageSchema/UnionSchema → InferSchema).
- Exporting a type function across modules works on 0.740 via a generic alias
  (`export type Infer<C> = InferImpl<C>`); v4's belief otherwise was wrong. Darklua bundles rename exported
  types `Name__DARKLUA_TYPE_<id>`; type functions survive bundling as aliases.
- The 11 caught mistakes: wrong payload type; wrong reply type; non-partition key in `show`; client
  firing with recipients; unknown flag; undeclared `oneOf` name; client collection write; Enum typo
  (`Lync.enum.Materail`); `latest` inside an event schema; `latest` after `unreliable`; client `limit`.
Gaps and caveats [I]:
- `update(id, patch)` is typed `{ [string]: unknown }` — patches are NOT inferred (would need a Partial
  type function; untested). `convert` required manual annotations. `namespace: <D>(D) -> D` validates
  nothing at type level. `Lync.all: Recipients` is faked as `Player | {Player}`.
- Everything rests on the **new solver**; Roblox runs `--!strict` scripts on the old solver unless the
  place opts in (`UseNewLuauTypeSolver`) [S research §1.2]. Most users would see `any`/errors. The attempt
  chose to ignore this ("no weakening types for the old solver") — a premise risk, not a finding.
- Checked only under luau-lsp 1.70.1, never in Studio's own analyzer; plugin-state types (`use():state`)
  flagged unverified [S].

## 5. Determinism findings

- Probe [V]: hashes the exact f64 bits of 19 ops (`sin cos tan asin acos atan exp log log10 sqrt sinh
  cosh tanh atan2 pow fmod noise divide multiplyAdd(a*b+0.1)`) over 4401 inputs (±2000×0.0137, wide,
  ~1e15, ~1e-300); NaNs canonicalised and counted.
- Result [V]: Windows, Luau 0.740 CLI interpreted == native, bit-identical; Studio (Edit, Windows) gives
  the same 19 hashes as the CLI. Baseline hashes saved (e.g. `sin e612607e`, `multiplyAdd 89584b15`).
- **Not run**: live Linux server, macOS, iOS, Android clients — i.e. the only comparison that matters.
- Staff quote [S, DevForum 2025-03-31]: float results not guaranteed to match across hardware; reproducible
  software "had to switch over to things like fixed point arithmetic". Gaffer: `+ - * / sqrt` reproducible
  under same settings; transcendentals and FMA are the risk. Integer-valued doubles < 2^53 are exact.
- Design outcome [S]: W-46 — quantized decode is one multiply-add on an integer index; change detection
  compares indices; "no codec state depends on two machines agreeing on a float". So the wire made the
  probe moot. [I] The probe also never covered float32 paths (`buffer.writef32`, Vector3 components are
  f32 on Roblox), the `vector` type, or CFrame/quaternion math that the rotation codec uses.

## 6. Security model

Server authority (hard guarantees, v5-security §3) [S]:
- Assume the attacker reads/writes all client Lua state (`getgc`, `getupvalues`, `hookfunction`,
  `hookmetamethod`, `getconnections`, spoofed `debug.info`); the format is public; security never depends on
  secrecy. Shared schema is fine; **policy (validate/limit) stays server-side**.
- Inbound order: exactly one `buffer` arg → per-player token buckets for frames AND bytes from
  `buffer.len` (before decode) → (integrity) → strict decode → `limit` → `validate` → `intent` → plugins →
  listeners each in own thread.
- Strict, canonical decode: trailing bytes, nonzero padding, non-minimal varints/class codes refused; every
  count checked against remaining bits and declared max **before allocating**; NaN/inf refused unless allowed;
  enum/oneOf/union ids range-checked; instance sidecar consumed exactly and `IsA` checked.
- Spec limits [S]: frames > 1 MiB refused; decode allocation ≤ 1024 B per frame byte + 16 KiB, absolute
  64 MiB; zero-bit element arrays ≤ 128; pending requests per peer ≤ 4096; held blocks ≤ 1024.
- `limit(rate, burst?)`: token bucket per player per definition, starts full, runs before `validate`;
  `latest(rate)` implies limit 2×rate. Unsolicited replies dropped (matched on player+id).
- `validate` = stateless sanity, `intent` = may this player do this now (honest races possible); separate
  reasons so punishment can weigh them. Lync never kicks; it emits typed events; opt-in `Lync.escalate`
  with weights (Malformed/BadTag/Trap 10, OverBudget 3, Replayed 2, RateLimited/Invalid/Stale 1, Intent 0).
Client "anti-forgery" (cost-raising only, admitted defeated by A3–A6) [S]: 18-byte per-session record
(key+seed), per-session definition-id permutation (client→server only), 16-bit seq + 16-bit keyed tag
trailer (+4 B/frame), replay window (64-bit bitmap), `debug.info` caller attestation folded into the tag,
honeypot `:trap()` definitions hidden from types, "closure hygiene". All gated on unrun measurements M1–M8.
[V counted] None of the per-player byte budget, `intent`, replay window or forgery features made it into
the spec; the spec's inbound DoS bound is only the per-definition limit plus decode caps.

## 7. Failure / error model and limits

- Channels [S]: declaration mistake → throw eagerly at declaration line; caller mistake → throw at caller's
  line with value path (`[Lync] Chat:fire value.items[3].count must be a whole number from 0 to 99, got 120`);
  user callback fault → own pooled thread, engine reports natively (`ScriptContext.Error` fires);
  handler fault → asker gets `Unanswered`; validator/transform fault → `xpcall`, drop that message as
  `CheckRaised`, one native report per definition per window; untrusted input → counted, typed event,
  bounded console summary; expected outcomes → `Result`; internal invariant → `[Lync] internal error`.
- Finding the user's line [V in Studio]: Luau inlines local functions within a module, so
  `error(msg, 2)` from an inlined helper landed on `pcall` with no position. Fix: one raise function walks
  `debug.info` to the first non-Lync source frame. Every message starts `[Lync] ` (deliberate skill deviation).
- Observability [S]: typed frozen event union `Dropped|CheckRaised|Recovered|Mismatch|Pressure|Suppressed`,
  reasons `Malformed|OutOfBounds|Rejected|RateLimited|CheckRaised|NotAdmitted|Stale`, ≤16 events per key
  per 30 s window then one `Suppressed`; console = built-in observer via `LogService:Warn(template, ctx)`
  (`GetLogger` "not yet available" [V]); metrics in bits; profiler labels; `debug.setmemorycategory("Lync")` [V].
- Limits [S]: ids < 2^51; ≤64 non-partition fields; ≤16 namespaces/connection; ≤64 instances/call;
  reliable call 16 KiB; unreliable `985-6I`; 8-bit sequences; 16-bit stamps; settle 0.5 s; request
  timeout default 10 s; HELLO retry 0.5→4 s backoff, 30 s deadline; remotes-missing retry 10 s.
- Inconsistencies [I]: v5-security §3.2 "a frame is delivered whole or not at all" vs spec W-104 "messages
  decoded before a refusal must still be delivered" and F-18 "later messages still delivered";
  v5-failures "Lync never runs user code on its own stack" vs validators running inline in decode;
  v5-failures puts validators inside decode while v5-security runs them after a full-frame decode.

## 8. Testing / harness / tooling architecture

Harness (built, ~10.7k lines) [V]: `RandomSource` (xoshiro128** seeded via SplitMix32 on `bit32`,
records a tape; replays, zeros past end, max 4096 zeros), `Generators`, `Properties` (300 cases standard,
×0.1 quick, ×20 deep; per-case seeds), `Tapes` (Hypothesis-style shortlex shrinker: delete runs, zero runs,
lower words, redistribute weight between word pairs; ≤1000/10000 calls), `Timeline` (virtual clock,
`delay`/`advance`, simulated `frame` signal at 1/60 s), `Network` (three lanes; each frame has a **fate** =
list of delivery delays: `{}` lost, `{0}` once, `{0,0.05}` duplicated, `{0.2}` delayed, smaller later delay
= reorder; reliable lanes use only earliest delay and keep order; unreliable over `985-6I` dropped), `Roster`
(stand-in players), `World` (composes them; both views in one DataModel so client code is covered),
`Suite` (`prove(claims, title, body)`, `proveForAll`, `provePair`), `Check` (`equals` with NaN==NaN,
-0≠0; `throws` checks position names test file; `includesEvent`; `matchesGolden` with hex window),
`Recorder` (taps `LogService.MessageOut` + `ScriptContext.Error`: undeclared Lync output or unclaimed error
fails a test), `Conductor`/`Agent`/`Link` (multi-DataModel orchestration over a `HarnessChannel` remote,
barrier/post/await, buildId echo), `Statistics` (median, MAD, bootstrap CI, Tukey, Mann-Whitney),
`Reports`/`Printouts`/`Deliveries` (report JSON → HTTP POST to local receiver, else Output lines
`[LyncReport:<run>] i/n <crc32> <base64 piece ≤3900>`).
Coverage [V partially]: `ScriptContext:EnableCoverage` + `GetCoverageStats():GetHits()` works in a
play-test server DataModel (needs plugin security, so a driver — the Studio MCP — enables it via a `Driven`
attribute handshake before any require); gate = every executable line, exclusions keyed by exact line text.
Claim ledger: tests cite claim ids; `claims` (static) and `judge` (on reports) commands; seven proof kinds
(Tested, Scripted, Typed `-- proves A-n;`, Inferred `-- infers A-n;`, Declared `.ts`, Reviewed, Waived).
Benches (designed, not built): Micro/Scenario/Weigh/Anchor rows, fingerprint anchors for Studio-vs-live
optimisation level, bytes `payload` (exact) / `estimate` (`EncodingService` zstd + overhead) / `wire` (ruler).
Scripts (Lute 1.0.0, ~8.3k lines): `lute run scripts/run.luau setup|check|claims|judge|build|dev`;
`Toolchain` fetches sha256-pinned `Roblox.d.luau` (luau-lsp 1.70.1 globalTypes) and Full-API-Dump;
`Places` (`dev`) runs darklua watchers + rojo serve + an HTTP receiver; `Spec`/`Citations` parse claims;
`TypeTests` runs luau-lsp over `test/types`; `Variants` = 4 darklua variants as data.
Toolchain [S/V]: rokit 1.2.0 pins darklua 0.19.0, luau-lsp 1.70.1, lute 1.0.0, rojo 7.7.1, wally 0.3.2;
Bun 1.3.14 + tsc 5.5.3/5.9.3 + rbxtsc 3.0.0 for roblox-ts proofs. Darklua: `test` (retain_lines,
`IS_DEVELOPMENT=true`, `convert_require` luau mode), `bench` (src from release), `release`/`bundle`
(`dense` column_span 1000, inject flags, remove_unused_if_branch/while, filter_after_early_return,
remove_empty_do, remove_unused_variable, rename_variables incl. functions). Explicitly banned rules with
reasons: `remove_types`, `remove_attribute` (break types/@native), `remove_assertions`,
`convert_local_function_to_assign` (drops @native), `group_local_assignment` (const→local),
`convert_square_root_call` (inf result changes). `.luaurc` aliases `@src @test @bench @harness`.
Lute 1.0.0 gotchas [V]: `process.args[1]` is the script itself (self-spawn exhausted memory twice);
`process.run` has no timeout and no kill; `env` merges only; no stderr/`warn`; `io.write` hangs to a file;
`@std/json` mis-decodes `\u0000`; printer rewrites `const` as `local`; `lute check` rejects `read` indexers.

## 9. Research facts about Roblox networking (with claimed sources)

- Remote buffers get transparent zstd ("staff", Buffer beta post 2023-11-30). [V Studio] 4000 B/frame:
  2.8 KB/s zeros vs 241.9 KB/s random against 240 KB/s payload (`Stats.DataSendKbps`).
- `EncodingService:CompressBuffer/DecompressBuffer/GetDecompressedBufferSize` exist (docs; shipped by 2025-11).
- Per-call overhead ~9 B server→client, ~14 B client→server; 9-byte buffer arrives as ~12 B; merging forty
  9-byte buffers 480 → 360 B (ByteNet DevForum thread, community, 2024-02). [V] A buffer + short string
  costs ~6 B beyond the string's characters; a lone random buffer fits ~995 B unreliable.
- Plain-argument costs: number 9 B, string len+2, bool 2, Instance 4–6, Vector3 13, CFrame 13–21 —
  sources conflict (ffrostfall 2022; Packet Size Counter 2023-24; community).
- UnreliableRemoteEvent limit 1000 B since 2025-03-12 (900 at launch) (announcement thread). [V] counted
  **after compression**: zero buffers passed up to 8000 B, random dropped from 990 B. No ordering; may drop
  under bandwidth/CPU pressure (staff 2023-11-29).
- ~500 calls/s per client per remote type; excess reliable queues, excess unreliable drops (remote docs).
- No evidence Roblox merges calls (community, unverified). No official KB/s budget; "50 KB/s" is folklore;
  `NetworkPeer:SetOutgoingKBPSLimit` exists (performance docs). `Stats` gives aggregate kbps only.
- Studio `NetworkSettings`: delay, jitter, loss capped at 0.5% (announcement 2026-06-02).
- Require-by-string: `./ ../ @self/ @game/`; `.luaurc` aliases NOT supported on Roblox (2025-01-22, 2026-01-08).
- `const` live (release 713, 2026-05). New solver default only for nocheck/nonstrict; strict stays old
  unless `UseNewLuauTypeSolver` (general release 2025-11-20). Native codegen: server only; not live clients
  (docs; a 2026-09 Android claim unverified). luau#1468: 3+ consecutive `buffer.writeu32` failed native compile.
- `StudioTestService:ExecuteMultiplayerTestAsync` up to 8 clients (v715, 2026-04); `EndTest(value)`.
  `ScriptContext:EnableCoverage` (v715). LogService structured logging (v716; `GetLogger` v734, unavailable [V]).
- `task.delay/wait` resume on Heartbeat (frame-quantized); `os.clock` sub-µs monotonic; only
  `collectgarbage("count")`/`gcinfo` for allocation; GC cannot be forced.
- `error(msg, level>0)` adds `source:line:` only for strings; level 0 strips it (luaB_error source).
- Competitors [S]: Blink, Zap (IDL + codegen; main complaint = regeneration step), ByteNet (inactive),
  Packet (security issues), Warp, BridgeNet2, Red (archived), Squash. Blink self-bench FPS: Blink 42, Zap 39,
  ByteNet 32, plain 16. Top user asks: exact inferred types, no codegen step, docs, abuse protection,
  inspection, scale, TS parity.
- roblox-ts [S/V]: 3.0.0 (TS 5.5.3) latest release, `next` on 5.9.3, `Symbol.iterator` (#1826) unreleased;
  method vs `this: void` decides colon vs dot call, mixing is `noMixedTypeCall`; `noAny`,
  `noIterableIteration`, `noCommentDirectives` (no `@ts-expect-error`); [V] `collection[0] = x` emits no `+1`
  because an interface with a numeric index signature is not array-like; custom scope needs `typeRoots` +
  Rojo `node_modules` edits; `luau2ts`/`rbx-tsx` turn type functions into `any`.

## 10. Critique: why the attempt was "poor"

1. **No product.** Zero `src`. ~19k lines of harness and build tooling, ~670 claims and ~3k lines of design
   prose before a single codec. The "spec → infra → src last" order (goals) guaranteed this. [V]
2. **Bureaucracy as design.** Claim grammar parsed by tooling, never-reused ids, `Withdrawn.` rows,
   provisional markers, seven proof kinds, "Contradictions resolved" (24 rows), "Choices still to confirm"
   (20 rows), "Review choices". Effort went into the ledger, not the library. Claims are legalese
   ("Stream bit `i` of a frame is bit `i mod 8` of byte `i div 8`"), splitting one idea into 3–5 ids. [I]
3. **Infrastructure gold-plating.** Multi-DataModel Conductor/Agent/Link, HTTP receiver in Lute, CRC-32 +
   base64 Output chunking with 12 claims of its own, Mann-Whitney + bootstrap, optimisation-level
   fingerprint anchors, coverage exclusions keyed by line text, a TS compile gate with junctions — all for
   a library that did not exist. [I]
4. **Premises that undercut the goals.** (a) Studio-only testing with "CI does not run the suite" means no
   automated gate; it depends on an MCP Studio that was not even connected during wire design. (b) Exact
   types depend on the new solver that strict Roblox scripts do not use by default. (c) "Measure on
   Roblox" was the stated rule, yet wire decisions rest on CPython zstd and synthetic Gaussians. [I]
5. **Wire over-engineering for unmeasured gains.** Column modes with 4×16 trial encodes per column,
   STATE deltas, SlotSets, coalescing algebra, settle, lane stall/resume from a bit offset, request-id
   quarantine — large surface, many edge states, gains proven only offline. Roblox already zstd's every call.
   [I]
6. **Brittle framing.** No block length prefix: one bad/unknown block kills the rest of the frame, forced the
   bit-offset held-remainder machinery (W-188/204/205), and blocks skipping unknown definitions. Bits saved
   per block are tiny next to ~9–14 B call overhead. [I]
7. **Inconsistency across docs** (see §2, §7): `limit` signature, frame atomicity, validator placement,
   remote location (Folder in ReplicatedStorage vs under module instance), security never merged into spec,
   "no annotations" contradicted by the probe's `convert` and untyped `update`. [V by reading]
8. **Ugly/clunky surface spots**: set-literal `oneOf`, dual `latest`, side-dependent `sentAt` position,
   implicit namespace naming from module path, 4×2 event state types, metatable-proxy collections that need
   a TS adapter layer with weak maps and identity tables. [I]
9. **Security theatre risk.** Session key, id permutation, 16-bit tag, attestation, honeypots — admitted
   useless against anyone who reads memory, cost 4 B/frame + per-player server state, and none measured.
   Meanwhile the one hard DoS bound (per-player byte/frame budget before decode) never reached the spec. [I]
10. **Toolchain sprawl and fragility.** rokit + Lute 1.0.0 (pre-1.0.1 bugs worked around in docs) + darklua
    ×4 variants + rojo ×2 projects + wally + luau-lsp + Bun + two tsc versions + rbxtsc + pinned API dump +
    pinned typedefs; a self-spawning Lute probe exhausted the machine's memory twice. [V/S]
11. **Prose quality.** Overlong, repetitive, self-referential (docs cite each other's sections constantly),
    every rule re-justified; reads like an agent writing for an auditor, not a library author. [I]
12. **Determinism work was moot** (wire avoids float-mirrored state) and incomplete (one machine). [I]

## 11. Ideas worth keeping

- **Two views from one shared schema**, side-specific types, wrong-side calls as type errors; one verb per
  action matching Roblox vocabulary; payload-first callbacks; `Result` for requests (no throws).
- **Plain-table records + type functions** (`InferSchema` via phantom `_value`); type-function `error()` for
  custom messages; pass callbacks as arguments (never assign) so params infer; non-generic codec methods;
  key-set tables are the only exact literal-union form (but look for nicer syntax); export type functions
  via generic alias; read-only client collections via `read` indexer.
- **Server-only policy** (`validate`, `limit(rate, burst)` token bucket) — never in shared schema.
- **Per-field accuracy `(min, max, step)` in the value's unit, exact by default**; integer indices as the
  only mirrored state; compare indices for change detection.
- **Batching**: one call per recipient per lane per frame; few remotes; dense bit packing, byte-aligned
  strings; let Roblox zstd do generic compression; no own entropy coder without proof.
- Octahedral `direction`, smallest-three `rotation`, axis-aligned rotation shortcut, class codes / EG-k.
- Demote oversize unreliable to reliable instead of throwing; 16-bit ms stamps off `GetServerTimeNow`.
- Collections: server-assigned slots, partitions with `show/hide`, "never shown = nobody sees", `removed`
  not revealing delete vs hide, sections encoded once for all viewers.
- Handshake hashing per definition so mismatches **name the differing definitions**; schema never sent.
- Strict canonical decode; check counts against remaining bits before allocating; allocation caps; a
  per-player frame/byte budget before decode.
- Failure model: raise at user's frame via `debug.info` walk; callbacks in own threads (native tracebacks);
  bounded, typed observer events; silent by default; one `[Lync]` marker; memory category; profiler labels.
- Measurement tricks: unreliable "Payload went over by N bytes" ruler; `EncodingService` as zstd estimator;
  `Stats.DataSendKbps` sanity checks; `NetworkSettings` for loss/jitter; `EnableCoverage` in play server.
- Test infra concepts (smaller): seeded bit32 xoshiro, tape-based shrinking, "fate" network model,
  virtual `Timeline`, in-process `World` with transport/clock/roster seams, golden byte vectors.
- roblox-ts: hand-written `.d.ts`; `Equal<>`-style type tests; index write emits no `+1`; `this: void` rules.
- darklua rule blacklist above; `dense` column_span 1000; `convert_require` in luau mode for `.luaurc` aliases.
