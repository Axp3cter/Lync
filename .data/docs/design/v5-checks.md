# Lync v5: checks, claims, telemetry and sealed delivery

Draft 3.6, final pass, 2026-10-15. Part of the v5 design (`v5.md`); changes from draft 3.5 are in `v5-changes.md` ("Draft 3.5 to 3.6").
This file specifies, completely:
- **checks** (§1–§6): `within`, `monotonic`, `maxTotal`, `derive` and `maxRate`, declared on the server view;
- **claims** (§7): the `:claim()` and `:input()` codec markers, the claim requirement and the `freeFormRoleMissing`
  lint;
- **telemetry** (§8): `aim`, `series`, `atom`, delivery to game code, and what Lync's docs must say about
  Roblox's terms;
- **sealed delivery** (§9): server-sent values sent before they become visible and revealed by a key.

They were draft 3.5's `checks` and `telemetry` extensions and R34's form (a); they are now part of the core. The
markers and their hash (§7.1) are built in milestone 1, the claim requirement with validators in milestone 2, the
lint in milestone 3, and the rest in milestone 7 (`v5.md` §10). Codes, counters and options this file adds are
listed in §10; pending measurements in §11.

Every part follows `v5.md` §0: Lync reports facts with exact triggers and numeric evidence, and never rewrites a
value a client sent. A message is dropped only for a rule the developer declared: a `validate` returning `false` or
a check with `policy = "drop"`, as `limit` and traps already do (`v5.md` §6.1). Every bound is the developer's
option; Lync derives none from a model of the network. Nothing here scores, ranks, delays or throttles a player.
Names follow `reviews/v5-3.6-naming.md`.

## 1. Checks: the common frame

### 1.1 Decision: where checks are declared

- **Problem.** A check compares a client value with server truth, so it needs server functions and server-only
  bounds. The shared schema is evaluated on the client, can't hold functions, and is readable by a modified client.
- **Options:** (a) codec methods in the shared schema (`t.int(0, 1000):maxTotal(5000, 600)`); (b) **calls on the
  server view**, as `:trap()` and the field handles' `refers()` and `canary()` are (`v5-integrity.md` §3, §8, §9).
- **Choice: (b)** `[checks-telemetry C0]`. References are server functions. Bounds stay off the client, since the
  server shard is never replicated (`v5.md` §3.5), so a modified client can't read a tolerance and use exactly all of
  it. Checks change no bytes, so they stay out of the schema hash (`v5.md` §4.7) and a retune needs no client
  rebuild. `:claim()` stays in the shared schema (§7.1), because the planner and the lint must see it.

### 1.2 Shape and scope

`Net.<definition>.fields[path]:<check>(options)`, with `<check>` one of `within`, `monotonic`, `maxTotal`, `derive`,
`maxRate` (`Net.strike.fields.origin:within({ … })`, `Net.shot.fields["hit.at"]:within({ … })`). The examples use
`v5.md` §3.4's `strike` with one claim field added, `origin = t.vector3(-2048, 2048, 1 / 32):claim()`, as §7.3's
schema declares it; the core's example and its golden vectors (G8, ROT) keep the two-field `strike`.
- **`fields`** is `v5.md` §3.4's table of field handles: a key is a path of `data` through records and optionals,
  dots between names (`""` is `data` itself when it isn't a record); arrays, maps and union variants are not
  reachable; a key naming no field is a type error where types are checked and throws `fieldPathUnknown` at the
  read. A check on a field whose codec it doesn't take throws `fieldCodecUnsupported`. Checks take leaf codecs
  only, so a check is always on the leaf it verifies (§7.2).
- **Types.** Each handle's type is emitted from its field's codec and has exactly the declarations that codec takes,
  each one non-overloaded method, so options such as `derive`'s `fn` are typed by the field and a check the codec
  doesn't take is a type error (`v5.md` §3.4). Exact on both solvers on the generated path; on the runtime path
  exact under the new solver only, as every runtime-path type is (`v5.md` §3.2); under tsc the `fields` type is exact
  and the per-codec interfaces are unverified (`v5.md` §3.6).
- **Scope.** `data` of client-sent events, of client requests' asks, and of streams (`Lync.stream`,
  `v5-collections.md` §15), whose checks run per index at playout (§1.4). Replies to server `invoke`s are not
  covered: answers have no validator step, and the code that called `invoke` checks its result. A check declared on
  a field of a server-sent definition or a collection throws `declarationMisplaced`.
- **An absent optional.** A check whose field passes through an optional that is absent in a message is not
  evaluated for that message and changes no state.
- **When.** A check may be declared at any time; it applies to messages decoded after the call. There is no call
  that removes one. Its **index** is its 1-based position among the definition's checks in declaration order.
- **R35's modifiers** `[refusals-rejudged-4 R35]`: `maxRate` is the fifth check (§6), with `planar` as its `plane`
  option and as a `within` reference (§6.3); `exempt` is `resetChecks`' `exemptSeconds` (§1.6); `cooldown` stays
  `limit` (§6.5).

### 1.3 Decision: what a failing check does

- **Problem.** A check's failure needs an outcome. Lync must not pick a consequence, must not rewrite what the
  client sent, and must let a game measure real traffic before it refuses anything.
- **Options:**
  - (a) the research's `"drop" | "clamp" | "deliver"`. `"clamp"` replaced the value by the nearest one the check
    accepts before delivery `[checks-telemetry C0]`. That is Lync rewriting client input: the handler would receive
    a value no client sent, and the fact would be the only trace of the original.
  - (b) **`"drop" | "deliver"`, required, with no default.** A game that wants a bounded value bounds it in its
    handler, where it already holds the reference.
  - (c) report-only checks, with `validate` as the only refusal. A game would then repeat each check's comparison in
    its validator to refuse on it.
- **Choice: (b).**
  - **`"drop"`:** the message is dropped and not delivered; an ask is answered `rejected`, the outcome a `validate`
    refusal gives (`v5.md` §5.2). The drop is the developer's declared rule, as `limit` is.
  - **`"deliver"`:** the message is delivered unchanged. It follows R25's rule (delivered and reported) and lets a
    game set a tolerance from real traffic before it drops anything.
  - **No default:** a default would be Lync choosing between dropping and delivering.
  - **What replaces `"clamp"`:** game code. The check runs with `"deliver"` (its fact, §1.5, records the
    failure), and the handler limits the value with the formulas `clamp` used, given in the docs per codec: scalars
    r + clamp(v − r, −m, m); `t.angle` r ± m wrapped into [0, 2π); vectors r + (v − r) · m/|v − r|; for `maxTotal`,
    max(0, total − S), which game code tracks itself. Lync offers no call for it, because a second way to rewrite
    would be the rejected option again.
  - Every failing check is reported by its check's fact (§1.5), whatever the policy.

### 1.4 Where checks run

`v5.md` §6.1's steps 5–7 run as follows:
- **Step 5**, as `v5.md` §6.1 lists it: control messages; answers (`requestSlotMismatch`, `requestAnswerBelowPing`);
  enum and instance resolution (`enumValueUnresolved`, `instanceUnresolved`, `instanceClassMismatch`); reachability
  (`unreferencedMessageReceived`, `genericIdMessageReceived`); `limit` (`limitExceeded`); traps
  (`trapMessageReceived`, dropped after `limit`, `v5-integrity.md` §3); then the report-only checks of milestone 5.
  Messages over `limit`, and traps' messages, therefore never touch check state.
- **Step 6, checks and validator**, per message of a definition, in this order (the claim requirement is enforced
  earlier, when the handler is declared, §7.3):
  1. **Evaluate** every check of the definition in declaration order. Each check reads its field once, at its own
     evaluation, and later steps use the value it read. Each failure records one occurrence of its check's fact
     (§1.5). A game function a check calls (`within`'s `reference`, `derive`'s `fn`) runs by `v5.md` §6.1's
     callback rule (§1.7) and receives the same `data` table the validator and the handler receive; a change it
     makes to `data` is seen by later checks, the validator and the handler, never by a check that has already read
     its field.
  2. If any failing check has `"drop"`, the message is dropped (an ask is answered `rejected`); the validator is not
     called and nothing is committed.
  3. **Validate**, as today: `false`, a throw or a yield drops the message.
  4. **Commit**, for every message that passes step 6 (*accepted*, `v5.md` §3.5), whether or not a handler then
     receives it (`messagesUnhandled`): `monotonic` and `maxRate` store, `maxTotal` charges, each the value it read
     at step 1. A failing check with `"deliver"` commits too, so check state is a function of the accepted
     messages.
  Messages of one frame are handled in order, each committing before the next is evaluated.
- **Step 6b, sample** (§8.3), then **step 7, delivery**.
- **Streams** (`v5-collections.md` §15.4): steps 5–7 run per index at its playout, in index order (`limit` doesn't apply
  to streams), and a drop drops that index. The frame key of `monotonic` and `maxRate` is the index (§3.1), and
  `maxRate`'s t is the index's playout time (§6.2).

Checks run before the validator, so a validator sees only messages that passed every `"drop"` check. Report-only
checks of milestone 5 stay in step 5, so they see messages a check or a validator later drops, as they already see
messages a validator drops.

### 1.5 The facts: one code per check

One code per check, by the splitting rule of `v5.md` §7.3 (`reviews/v5-3.6-naming.md` §11.2: a trigger gets its own
code when its subject or its fix differs): the five checks differ in trigger, options, evidence and known causes.
Evidence narrows on `code`, the form proven on both solvers `[probes review-2 t3]`, so no code carries a field it
has no use for.

| Code | Exact trigger | Evidence beyond the common fields | Known causes on an unmodified client |
|---|---|---|---|
| `withinExceeded` | a `within` check fails (§2.2) | none | §2.4 |
| `monotonicOutOfOrder` | a `monotonic` check fails (§3.2) | `olderFrame` | §3.4 |
| `maxTotalExceeded` | a `maxTotal` check fails (§4.2) | none | §4.4 |
| `deriveMismatch` | an evaluated `derive` check fails (§5.2) | none | §5.3 |
| `maxRateExceeded` | a `maxRate` check fails (§6.2) | `spanSeconds`, `failedReference`, `olderFrame` | §6.4 |

- **Action**, for every code: under `"drop"` the message is dropped (an ask is answered `rejected`); under
  `"deliver"` it is delivered.
- **Common evidence:** `checkIndex` (the check's 1-based index, §1.2), `policy` (1 drop, 2 deliver), `observed`,
  `bound` (below, in the field's unit), and on a window's closing fact `peakObserved`, `peakBound` (below).
- **Per code:**

| Code | `observed` | `bound` |
|---|---|---|
| `withinExceeded` | the distance d | the maximum distance applied to this message |
| `monotonicOutOfOrder` | the value | the stored value |
| `maxTotalExceeded` | the window sum S plus the amount | `total` |
| `deriveMismatch` | the distance d after snapping (1 for an unequal `t.enum` or `t.bool`) | `tolerance` |
| `maxRateExceeded` | d against the failing reference | that reference's allowance, `perSecond` × `spanSeconds` + `tolerance` |

  `olderFrame` is 1 when the message's frame key is older than the stored key (§3.2, §6.2), possible only on the
  unreliable lane (§3.1), else 0. `spanSeconds` (s) is t − t_p or t − t_a, for the failing reference;
  `failedReference` is 1 the previous value, 2 the anchor (1 when both fail).
- Evidence is numbers from the decoded value and the server's own value, never client bytes.
- **Decision: one window per check** (review M2). Problem: `v5.md` §7.3 keys a window by (player, code, namespace,
  definition), so two checks of one code on one definition (two `within`s on two fields) coalesce and the closing
  fact carries only the last occurrence's evidence; the tuning workflow (run `"deliver"`, read `observed`, set the
  bound, §2.4, §5.3) needs each check's own numbers, and the largest of them. Options: (a) the core key, last
  occurrence only; (b) **the key gains `checkIndex`, and the closing fact also carries the window's peak**.
  Choice: (b). The key is (player, code, namespace, definition, `checkIndex`), and a closing fact carries
  `peakObserved` and `peakBound`, the `observed` and `bound` of the window's occurrence with the largest
  |`observed` − `bound`| (the first such on a tie; on a fact delivered at a window's first occurrence they equal
  `observed` and `bound`). Both are a maximum of reported numbers, exact, not a statistic about a player. The caps
  (`observe.maxFactsPerPlayer`, `observe.maxFacts`) count each key as core keys do.
- Recording costs 20.5 ns native per occurrence `[diagnostics §9]`.

### 1.6 State and `resetChecks`

- **State** is kept per (player, check), or per (player, pool) for a `maxTotal` pool. It is allocated at the
  player's first message that reaches the check and freed when the player leaves.
- **`Net.<definition>:resetChecks(player, options?)`**, `options = { exemptSeconds, checkIndex }`, clears that
  player's state for the scoped checks, including the windows of the pools their `maxTotal` checks belong to. The
  scope is the check at index `checkIndex`, whatever its kind; with `checkIndex` nil, every check of the definition
  that keeps state (`monotonic`, `maxTotal`, `maxRate`), since only state needs reseeding: `within` and `derive`
  keep running (review M1). For `exemptSeconds` after the call, the scoped checks don't evaluate that player's
  messages of the definition and commit nothing; each such message is counted once in `checksExempted`. After the
  window, the next message seeds the state. It is the call for rounds, respawns and teleports.
- **Why a duration** `[refusals-rejudged-4 R35]`: messages the client sent before a server-applied move are still in
  flight after the call, and with an instant reset the first of them reseeds `maxRate` or `monotonic` with the old
  value, so the first message after the move fails: one fact per teleport, with `observed` about the teleport's
  distance. No frame key separates them, since those frames are newer than any the server has seen. The docs'
  formula for `exemptSeconds` after a server-applied move on `v5.md` §9's model: the client keeps sending old
  values until the move reaches it, and they arrive a one-way trip later: 2 × (0.05 + 0.02) s, plus a server flush,
  a client frame and a server step of 1/60 s each, 0.19 s; on the reliable lane add the definition's `limit.slackSeconds`
  (2 s by default, `v5.md` §3.4). The game knows its own ping (`GetNetworkPing`).

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `exemptSeconds` | number (real) | s | 0–10 | 0 (chosen: an instant reset) | one time comparison per message of the definition while a window is open |
| `checkIndex` | integer or nil | 1-based check index | 1 to the definition's check count | nil: every check of the definition | none |

### 1.7 Game functions inside checks

- **The rule is `v5.md` §6.1's callback rule,** the one rule for every game function whose result Lync needs before
  it goes on: a reused runner thread per call site, three outcomes (returned, threw, yielded), and on a yield
  `task.cancel`, then the declared fallback. The reason (collections review B2, checked): Luau lets a coroutine
  yield across `xpcall`, so a game function that yields under `xpcall` (`task.wait`, `WaitForChild`, a DataStore
  call) suspends the thread running the inbound pipeline, and that frame's remaining messages and the flush wait
  until the engine resumes it (`reviews/v5-3.6-collections.md` B2; checked again with luau 0.740: a "flush"
  coroutine calling a yielding function under `xpcall` returned `suspended` and never reached its end).
- **For a check's `reference` or `fn`:**
  - **returned:** the results are the function's. A result outside the check's domain is raised inside the runner
    before its completion marker, so it is a throw: the wrong type, a non-finite number or component, a fraction
    for a `t.int` field, or, for `derive` on `t.direction`, a zero vector (§5.1);
  - **threw:** reported natively as `checkFunctionRaised`, with `debug.traceback(thread, message)`;
  - **yielded:** reported natively as `checkFunctionYielded`; whatever the function did before its yield stays done.
  The declared fallback is the drop: on a throw or a yield the message is dropped (an ask is answered `rejected`),
  checks after it are not evaluated, occurrences already recorded stand, and the definition's `checkFunctionsRaised` or
  `checkFunctionsYielded` counter rises by one (`v5.md` §7.4). Native reports are spaced per (code, definition) per
  `observe.windowSeconds`, and name the function (`arena.strike.fields.origin:within reference`). The pipeline
  thread never runs game code, so a yield costs nothing to the frame or the flush.
- A function returning nil skips its check for that message, counted in `checksSkipped`; nothing is committed for
  that check.
- **Cost** (checked, luau 0.740 CLI, interpreted, best of 5 × 2 × 10^6 calls of a two-argument function): a direct
  call 22.5 ns, under `xpcall` 28.3 ns, through a reused runner thread 101.5 ns, through a new thread per call
  245.3 ns. So the runner adds about 73 ns per game function against `xpcall`, plus one thread creation after each
  throw or yield; native and Roblox's build are unmeasured (§11). `v5.md` §6.1 cites these figures.
- **`Lync.perception(player)`** (`v5-collections.md` §12.5) works in every synchronous call Lync makes for a
  message from `player`: a `reference` or `fn`, the validator, and the handler before its first yield. It returns a
  frozen value of the frame's and the player's inputs only, the same in each call (for a stream index, the value
  kept with the index); anywhere else, or for another player, it throws `perceptionMisplaced`. A reference that
  rewinds reads P from the collection's `rewound` result, whose `tick` is P:
  `Net.fighters:rewound(Lync.perception(player), key)`.

## 2. `within`

### 2.1 Semantics

`Net.strike.fields.origin:within({ reference = rootOf, maxDistance = 6, policy = "drop" })` `[checks-telemetry C1]`.
- Per message Lync calls `reference(player, data)`, which returns `(r, m?)`: the server's value to compare against,
  and optionally a maximum distance for this message alone (speed × elapsed time, say), which replaces
  `maxDistance` for it. r nil skips the check (§1.7).
- **Distance d**, by the field's codec:
  - `t.int`, `t.number`, `t.f32`, `t.f64`: |v − r|;
  - `t.angle`: min(δ, 2π − δ) with δ = |v − r| mod 2π;
  - `t.vector3`, `t.vector3f32`: |v − r|;
  - `t.direction`: acos(clamp(v · r̂, −1, 1)), with r̂ = r/|r| (r = 0 gives NaN).
- Other codecs (`t.cframe`, `t.rotation`, records, arrays, enums, strings, the rest) throw `fieldCodecUnsupported`
  (a type error where types are checked). A `t.cframe`'s
  position would need a path into the cframe, which paths don't define.

### 2.2 Exact trigger

not (d ≤ m), where m is the per-message maximum when returned, else `maxDistance`. Equality passes; a NaN d or m
fails; a negative m fails every value. Decoded values are never NaN (`v5.md` §3.3).

### 2.3 What it protects, and how it is defeated

- **Protects** claims about where something is relative to server truth: a shot origin against the shooter, reach
  (a claimed target against the player), a client-stated time against `GetServerTimeNow()`, a claimed tick against
  `Lync.tick()`. A forged value is bounded to the sphere or interval of radius m around r, on every message.
- **Defeated by:** any value inside the tolerance, on every message (the tolerance is the room a modified client
  has); a client-controlled reference, such as a root part under the client's network ownership, which makes the
  check compare two client values; a reference that follows the claim (a position the server accepts from the same
  client), along which in-tolerance claims add up. The docs state all three; Lync can't detect them.

### 2.4 Known causes on an unmodified client

1. **Latency between the client's value and the server's reference:** speed × (one-way latency 0.05 s + jitter up
   to 0.02 s + one client flush 1/60 s + one server step 1/60 s) ≈ 0.10 s on the default network (derived, `v5.md`
   §5.1, §9); 1.6 studs at the default `WalkSpeed` of 16 studs/s (documented), and 13.6 studs more after a 0.85 s
   reliable-lane stall (the simulated p99, `v5.md` §5.4). For physics the client owns, the engine's replication
   delay adds an unmeasured amount (§11). A reference that reads `rewind` at the client's perceived tick
   (`Net.c:rewound(Lync.perception(player), key)`, `v5-collections.md` §12.5) removes the latency term for records
   Lync replicates.
2. **Teleports, respawns and seat changes** between send and arrival.
3. **Quantization:** up to √3 · step/2 for `t.vector3` (0.027 studs at 1/32), step/2 for `t.number`, π/n for
   `t.angle`, the octahedral error for `t.direction` (0.2369° at 10 bits; `v5.md` §3.3).
4. **A reference that measures something else** than what the client's code reads: the camera rather than the root
   part, a part's centre rather than its surface.

The docs' formula: `maxDistance` = speed × 0.25 s + the quantization error; start with `"deliver"`, read `observed`
over a play session, then choose `"drop"` or keep `"deliver"`.

### 2.5 Options and cost

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `reference` | `(Player, Data) -> (R?, number?)`; R is `number` for scalars and `t.angle`, `Vector3` for vectors and `t.direction` | — | — | required | the game's own, once per message, in its own runner thread (§1.7), about 101.5 ns interpreted per call |
| `maxDistance` | number (real) | the field's unit: studs, radians for `t.angle` and `t.direction`, the integer's unit | ≥ 0, finite | required | none |
| `policy` | `"drop" \| "deliver"` | — | — | required | none |

Measured, net of the runner's per-message baseline `[checks-telemetry C6]`: 50–56 ns native and 101–109 ns
interpreted per message for a vector field, 47–49 and 108–116 ns for a number field; a failure adds 20.5 ns native.
State 0 B; wire 0 B.

## 3. `monotonic`

### 3.1 Semantics

`Net.input.fields.seq:monotonic({ order = "increasing", policy = "drop" })` `[checks-telemetry C2]`: a number that
unmodified client code never decreases in send order (`"nondecreasing"`) or always raises (`"increasing"`).
- **Frame key.** On the reliable lane, the number of reliable frames the server has accepted from the player on
  this connection before this one, counting from 0 (the wire unit defines the count, `v5.md` §4.5); on the
  unreliable lane, the frame's extended upstream seq (`v5.md` §4.4); on a stream, the index, which is delivered in
  index order, so no stream value is in an older frame (`v5-collections.md` §15.4). Messages of one definition in one
  frame are in call order (`v5.md` §4.1), so they share a key and are compared in order.
- **Why not the tag count** (review B1, checked by the reviewer's probe): `REKEY` restarts the tag count at 0 (`v5.md`
  §4.5), so after one `tagMismatchesExceeded`, a known cause on an unmodified client, every reliable frame would be
  "late" until the new count passed the old one: 999 of 1000 rising values failed `"nondecreasing"`, and 999 of 999
  stale values passed, which a client can force with 8 bad tags. The accepted count is never reset, and reliable frames
  arrive in order, so no reliable frame is late.
- **State:** the stored key s* and value v*, two f64 per (player, check).
- Codecs: `t.int(min, max)`, `t.int()`, `t.number`, `t.f32`, `t.f64`. `t.angle` wraps, so it is
  `fieldCodecUnsupported`, as is every other codec.

### 3.2 Exact trigger

For a value v in a frame with key s:
- no stored value: never fails;
- s ≥ s*: fails when v < v* (`"nondecreasing"`) or v ≤ v* (`"increasing"`); `olderFrame` = 0;
- s < s* (a late frame, possible only on the unreliable lane, §3.1): fails when v > v* (`"nondecreasing"`) or v ≥ v*
  (`"increasing"`), since a value sent earlier can't exceed one sent later; `olderFrame` = 1.

**Commit** (§1.4): for s ≥ s*, (s*, v*) ← (s, v); a late frame stores nothing.

**Why the key** (`checks-telemetry/monotonic_reorder.out`): on `v5.md` §9's default network, 1.31–1.33% of
delivered unreliable frames arrive after a newer one, none 64 or more behind. A rule against the last accepted value
fails on each of them, 23.6% of frames at 0.05 s jitter; the keyed rule fails on none, as `v5.md` §9 requires.

### 3.3 What it protects, and how it is defeated

- **Protects** values a modified client sends back stale through Lync's API: an earlier sequence number, timestamp
  or idempotency key re-sent in a new frame (the tag and replay window pass a new frame), claimed times running
  backwards.
- **Defeated by** any rising value, a jump far ahead included. A client-stated time also needs `within` against
  `GetServerTimeNow()`.

### 3.4 Known causes on an unmodified client

1. **Game code restarting the value:** a new round, a respawn, a script-local counter that restarts. A `LocalScript`
   under `StarterCharacterScripts` is copied into each new character, so its locals restart at every respawn
   (documented). The fix is `resetChecks(player)` at the reset, or a counter kept in `PlayerScripts`.
2. **A counter that wraps** inside a bounded `t.int(min, max)`.
3. **Quantization merging values:** two rising values that decode equal (one `t.number` step, f64 values rounding to
   one f32) fail `"increasing"`.
4. **A clock that can be set back:** the device wall clock (`os.time()`, `DateTime.now()`), user-settable
   (unverified on Roblox devices); whether `GetServerTimeNow()` can decrease on a client is unmeasured (§11).

Not causes: loss (gaps pass), reordering (the key), duplicates (the replay window drops them).

### 3.5 Options and cost

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `order` | `"nondecreasing" \| "increasing"` | — | — | required (review m2: which values `"drop"` refuses is the game's rule about its own counter, §1.3's reason; `"nondecreasing"` accepts repeats) | none |
| `policy` | `"drop" \| "deliver"` | — | — | required | none |

Measured, net: 57–63 ns native and 175–183 ns interpreted per message `[checks-telemetry C6]`. State 16 B per player
per check; wire 0 B.

## 4. `maxTotal`

### 4.1 Semantics and the window

`Net.collect.fields.coins:maxTotal({ total = 5000, windowSeconds = 600, policy = "drop" })` `[checks-telemetry C3]`
bounds the running sum of a field per player over a window timed by server arrival on `os.clock()`, never by client time
(R20, R21).

**Decision: the window mechanism** (`checks-telemetry/maxtotal_bounds.out`, `total` 1000, `windowSeconds` 60, a message
every 0.05 s for 600 s):

| Mechanism | Largest accepted sum, greedy sender | State per player | Cost, native (net) |
|---|---|---|---|
| (a) **sliding window of 16 buckets** | any 56.25 s: 1.00 × `total`; any 60 s: 2.00 × `total`; long run: `total`/`windowSeconds` | 144 B | 74–84 ns |
| (b) token bucket (capacity `total`, refill `total`/`windowSeconds`) | any 56.25 s: 1.94 × `total`; any 60 s: 2.00 × `total` | 16 B | 65–66 ns |
| (c) exact window, a ring of every committed (time, amount) | any 60 s: `total` (derived) | 16 B per message in the window, 48 KB per player per check at 5 messages/s over 600 s (derived), and a `limit` to bound it | not measured |

- **Choice: (a).** A rule written per window ("5000 coins per 10 minutes") means a sum over the window; (a) bounds any
  span of up to 15/16 × `windowSeconds` to `total` exactly, in constant memory and without requiring a `limit`. (b) lets
  a sender take 1.94 × `total` within 15/16 of the window. (c) is exact for 330× (a)'s memory at the example rate.
- **The bucket count, 16,** is a runtime constant (chosen: it sets the guarantee at 15/16 of the window for 144 B;
  32 buckets would give 31/32 for 272 B. A game rule that needs the full window would change it).

### 4.2 Exact trigger

Let w = `windowSeconds`/16, k = ⌊`os.clock()`/w⌋ at evaluation, and S the sum of amounts committed for (player, check or
pool) in buckets k − 15 … k. The check fails when S + v > `total`. **Commit** (§1.4) adds v to bucket k.
- **Exact arithmetic** (review m1, checked by the reviewer: in f64, 0.1 + 0.1 + 0.1 > 0.3, so a third 0.1 would fail a
  0.3 `total`). Amounts are summed as integers: for `t.int`, the value; for `t.number(min, max, step)`, the value in
  units of `step`, (v − min)/step + min/step, which is an integer because the decoder gives min + q · step and `min`
  must be a multiple of `step` (within `v5.md` §3.3's 1e-9 rule; otherwise `fieldCodecUnsupported`). `total` is
  converted once, at declaration, to ⌊total/step⌋ units by the same 1e-9 rule. S is recomputed from the 16 bucket sums
  at each evaluation, never kept by adding and subtracting, and every sum is an integer below 2^53 (`total` ≤ 2^53
  units).

**Guarantee** (derived, and measured above): any span of 15/16 × `windowSeconds` or less holds at most `total` of
committed amounts while every failing message is dropped; any span of `windowSeconds`, at most 2 × `total`; the long-run
rate is at most `total`/`windowSeconds`. Under `"deliver"`, failing amounts are committed too (§1.4), so S is the sum
game code received and `observed` reports how far it went past `total`.

- **Codecs:** `t.int(min, max)` and `t.number(min, max, step)` with min ≥ 0. `t.int()`, `t.f32`, `t.f64` and any
  codec with negative values are `fieldCodecUnsupported`: a negative amount would refund the window.
- **`pool`:** checks with the same pool name, on any definitions of the namespace, share one window per player (coins
  from `collect`, `sell` and `quest`). They must declare equal `total` and `windowSeconds`, and fields of equal unit
  (equal `step` for `t.number`), else `checkPoolMismatch`. A pool whose checks mix `"drop"` and `"deliver"` commits the
  `"deliver"` checks' failing amounts too, so the guarantee above holds only for pools whose every check drops.

### 4.3 What it protects, and how it is defeated

- **Protects** the rate of gain of client-claimed amounts (currency, experience, items or damage in a claim field):
  Roblox's documented "Rate of Gain" heuristic `[anticheat-design §4.2]`. A forged sequence of amounts is bounded to
  `total` per 15/16 window and `total`/`windowSeconds` in the long run.
- **Defeated by** claiming exactly the allowance every time, and by spreading amounts over definitions that aren't
  in one pool. It is no substitute for computing the gain on the server, which needs no check.

### 4.4 Known causes on an unmodified client

`checks-telemetry/maxtotal_bounds.out`:
1. **A `total` below what play produces** within 15/16 × `windowSeconds`: a bonus event, a purchase that doubles rates.
2. **A sender at exactly `total`/`windowSeconds`** fails at bucket edges: 10 of 12,000 amounts with no stall, 84 with
   one 5 s reliable stall.

Not causes: stalls with headroom (at 90% of `total`/`windowSeconds`, no failure with one stall of 0, 0.85, 2 or 5 s);
lost messages (never charged); messages `validate` refuses (never committed). The docs recommend 10% headroom, from this
measurement.

### 4.5 Options and cost

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `total` | number (real) | the field's unit, per window | > 0, ≤ 2^53 | required | none |
| `windowSeconds` | number (real) | s | 1–3600 | required | bucket width `windowSeconds`/16 |
| `pool` | string or nil | — | 1–64 B | nil: the check's own window | one window per player per pool instead of per check |
| `policy` | `"drop" \| "deliver"` | — | — | required | none |

Measured, net: 74–84 ns native and 240–248 ns interpreted per message, including clearing up to 16 sums when a
message enters a new bucket `[checks-telemetry C6]`. State 144 B per player per check or pool; wire 0 B.

## 5. `derive`

### 5.1 Semantics

`Net.shot.fields.landing:derive({ fn = landingOf, tolerance = 0.25, policy = "deliver" })` `[server-facts §U9.2]`: the
server re-computes an outcome the client sent from the inputs in the same message and compares.

```luau
-- server
local Projectile = require(ReplicatedStorage.Shared.Projectile) -- the module the client also calls
Net.shot.fields.landing:derive({
	fn = function(player, shot) return Projectile.landing(shot.origin, shot.velocity, shot.flight) end,
	tolerance = 0.25, -- studs
	policy = "deliver",
})
Net.craft.fields.result:derive({
	fn = function(player, craft) return Recipes.result(craft.recipe, craft.inputs) end,
	tolerance = 0, -- t.enum: exact
	policy = "drop",
})
```

- **Decision: shape.** Options were the research's `:claim(Lync.derive(fn, tolerance))` in the shared schema
  (refused by M8: functions can't live in the shared schema), a docs recipe over `within` (it compares an unsnapped
  value, can't take `t.enum` or `t.bool`, and reports `withinExceeded`, whose causes are latency), and **a fourth
  check**. Choice: the fourth check, which reuses §1 whole and adds snapping, exact codecs and its own code
  `[server-facts §U9.2]`.
- **Comparison:**
  1. `fn(player, data)` returns r, or nil (§1.7). A non-finite r (or component), and a zero vector for
     `t.direction`, is raised inside `fn`'s thread, so it is a throw (§1.7, review M4): the snap only sees finite
     values in the codec's domain, and no game value reaches the encoder's `internal`.
  2. **Snap:** r goes through the field codec's own quantizer, the one the encoder applies (`v5.md` §3.3):
     `t.number` and each `t.vector3` component to its step, `t.angle` to its n, `t.direction` through the octahedral
     code, `t.f32` to the nearest f32. A value outside the codec's range is first limited to it (this is the
     server's value; the client's is untouched). `t.int`, `t.f64`, `t.enum` and `t.bool` are compared as returned.
  3. **Distance, in codes where the codec has a grid** (review M3, checked by the reviewer: decoded neighbours at
     decimal steps lie up to 1.4e-13 beyond `step`, so a float metric fails a one-step tolerance about a quarter of
     the time). With q_v the received code and q_r the snapped one: `t.number` and `t.int(min, max)`, k = |q_v −
     q_r|; `t.vector3`, k = Σ Δq² over the components; `t.angle`, k = min(Δq, n − Δq). `tolerance` is converted once,
     at declaration, to an integer K by `v5.md` §3.3's 1e-9 rule: ⌊tolerance/step⌋ for `t.number`, ⌊tolerance⌋ for `t.int(min, max)` (step 1),
     ⌊(tolerance/step)²⌋ for `t.vector3`, ⌊tolerance · n/2π⌋ for `t.angle`. The comparison is integer: k against K.
     `observed` reports √k · step, k · step or k · 2π/n in the field's unit. `t.direction`, `t.f32`, `t.f64` keep
     §2.1's float metric; `t.enum` (both forms) and `t.bool` give 0 or 1.
- **Codecs:** §2.1's list, plus `t.enum` and `t.bool`. Records, arrays, maps, unions, `t.cframe` and `t.rotation`
  are `fieldCodecUnsupported`; a record outcome is one `derive` per leaf.
- `derive` keeps no state; commit stores nothing.

### 5.2 Exact trigger

The check is evaluated for a message when `messagesPerCheck` is 1, or when a draw `Random:NextInteger(1,
messagesPerCheck)` returns 1 from a `Random.new()` instance created without a seed at server start and used for nothing
else (an unseeded `Random` "uses a seed from an internal entropy source", documented, creator-docs
`datatypes/Random.yaml`). The draw happens after the frame arrived, so a client can't know before sending which of its
messages are evaluated. An evaluated check fails when not (k ≤ K) on a grid codec, or not (d ≤ `tolerance`) on the
others (§5.1 step 3); equality passes. A message not drawn is not evaluated, passes, and is counted in `checksUndrawn`
(review M1), so every way a claim passes unchecked has a count.

### 5.3 What it protects, known causes

- **Protects** the link between inputs and outcome: a client whose simulation constants were edited in memory, or
  whose outcome was edited after it was computed, sends a claim the server's recomputation doesn't reproduce.
- **Doesn't protect** the inputs, which are client-chosen and need their own checks (`within`, `limit`, `rewind`).
- **Defeated by** a modified client that computes its claims with the game's own shared function. The docs say the
  game acts on its own recomputation, never on the claim.

Known causes on an unmodified client (`server-facts/derive_determinism.out` unless marked):
1. **The same code gives different floats.** Native against interpreted on one machine: `math.lerp` and
   `vector.lerp` differ in 57,506 of 200,000 random lerps, by at most 2.27e-13, because native code fuses a
   multiply-add (verified from source); f32 against f64: up to 9.78e-5 studs per component, 154 of 300,000 components
   (0.051%) failing tolerance 0 at step 1/32, none by more than one step. Across devices (arm64 clients, other libm
   builds): unverified (§11). A tolerance of at least one grid step removes this cause while the gap stays under one
   step.
2. **A different algorithm:** per-frame integration on the client against a closed form in `fn`, after 1 s of flight
   at gravity 196.2 studs/s²: 3.27 studs off at 30 FPS, 1.64 at 60, 0.68 at 144, 0.41 at 240. Fix: one shared
   function.
3. **Inputs quantized after the client used them:** at 300 studs of flight, the 0.2369° of `t.direction(10)` is 1.24
   studs (derived). Fix: compute the outcome from the values as they will decode, with the client view's
   `Net.<def>:asDecoded(data)` (`v5.md` §3.5).
4. **Server state that differs from the client's,** when `fn` reads it: latency (§2.4 cause 1), parts not streamed
   in, moving geometry.
5. **Inputs that weren't sent:** the client's own clock, a random draw, local state. Fix: put them in the message
   (a seed, `Lync.tick()`) and check them with `within`.

**Tolerance.** In the field's unit, as `within`'s `maxDistance`. On a grid codec, k steps pass exactly at
`tolerance` = k · step (k · 2π/n for `t.angle`), and a diagonal neighbour of `t.vector3` at √3 · step
(0.0541266 studs at 1/32); one grid step is the smallest value that absorbs cause 1. For `t.direction`, one
octahedral cell (0.47° at 10 bits, derived from the 0.2369° maximum error) plus a margin the developer picks, since
its metric is a float angle. The docs' formula: one step + the gap
between the client's algorithm and `fn` + lever arm × input quantization error + speed × latency when `fn` reads
moving server state.

### 5.4 Options, types and cost

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `fn` | `(Player, Data) -> T?`, T the field's decoded type | — | — | required | the game's own, per evaluated message, in its own runner thread (§1.7) |
| `tolerance` | number (real) | the field's unit | 0–2^31, finite; only 0 for `t.enum` and `t.bool` | required | none |
| `policy` | `"drop" \| "deliver"` | — | — | required | none |
| `messagesPerCheck` | integer | messages per evaluation | 1–1000 | 1 (derived: principle 1, every message is checked unless the developer trades that for `fn`'s cost) | above 1: one draw per message, 24–32 ns in the CLI (`v5-integrity.md` §4's figure; `Random:NextInteger` on Roblox servers unmeasured, §11) and `fn` on 1/`messagesPerCheck` of messages on average; a message not drawn passes unchecked, under `"drop"` too |

- **Types.** `Net.shot.fields.landing` is the handle emitted for a `t.vector3` field of `ShotData`, whose `derive`
  takes `{ fn: (Player, ShotData) -> Vector3?, tolerance: number, policy: "drop" | "deliver", messagesPerCheck:
  number? }`, so `fn`'s return type is the field's (`v5.md` §3.4's field handles; roblox-ts the same, `this: void`,
  `v5.md` §3.6).
- **Measured** (`server-facts/server_facts_cost.out`): Lync's share for a vector field is 6–12 ns native and
  32–36 ns interpreted per message; with an exact compare (`t.enum`) the whole runner is 7.2–8.5 ns native. Add the
  runner thread (§1.7) and 20.5 ns per failure. State 0 B; wire 0 B.

## 6. `maxRate`

### 6.1 Semantics

`Net.move.fields.position:maxRate({ perSecond = 16, tolerance = 0.907, windowSeconds = 10, plane = "xz", policy = "deliver"
})` `[refusals-rejudged-4 R35]`: a claimed value that changes by at most `perSecond` (in the field's unit) per second.
- **Why a check, not a recipe.** A `within` whose reference returns the game's last delivered value plus `perSecond` ×
  elapsed fails twice: game code never sees frame keys, so late unreliable frames (1.3%, §3.2) move its last value
  backwards; and a per-step bucket accumulates quantization error. The research's leaky bucket on |Δ| reached
  149 studs (unreliable) and 309 studs (reliable) over 3 × 10^6 messages of a client moving at exactly 16 studs/s,
  `t.vector3` step 1/32 (`refusals-rejudged/r4_maxrate.out`), and it grows with session length. So the form compares
  samples pairwise against two references.
- **State** per (player, check), 80 B: the newest committed value p with its evaluation time t_p and frame key, and
  an anchor a with its time t_a.
- **Distance d(x, y):** §2.1's metric (`t.int`, `t.number`, `t.f32`, `t.f64`, `t.angle`, `t.direction`, `t.vector3`,
  `t.vector3f32`); for the two vector codecs with `plane = "xz"`, |x − y| over X and Z only. Other codecs are
  `fieldCodecUnsupported`.

### 6.2 Exact trigger

For a value v in a frame with key s, evaluated at t (`os.clock()` at evaluation): with no stored value, never. Otherwise
it fails when not (d(v, p) ≤ `perSecond` × (t − t_p) + `tolerance`), or not (d(v, a) ≤ `perSecond` × (t − t_a) + `tolerance`);
equality passes. A late frame (s older than the stored key, unreliable only: §3.1's key) is compared with both
references, `olderFrame` = 1. On a stream the key is the index and t the index's due time, θ_i + o + J / `stateRate` (its arrival when it
arrived late; `v5-collections.md` §15.4), so no frame is older and t advances by exactly 1 / `state.ticksPerSecond`
per index while the arrival offset holds (`v5-collections.md` §15.4).

**Commit** (§1.4): if s is newer than the stored key, (p, t_p, key) ← (v, t, s), and when t − t_a ≥ `windowSeconds` also
(a, t_a) ← (v, t). The first message sets both. A late frame stores nothing.

**Why two references.** The previous value bounds a jump against the last sample, so a jump can't spend allowance
accrued before that sample; the anchor bounds net displacement over up to `windowSeconds`, which catches sustained
excess speed that per-step comparisons let through. Each is one comparison of two samples, so honest error doesn't
accumulate.

**Decision: `tolerance` and `windowSeconds` are required.**
- **Problem.** `tolerance` must cover an honest pair's excess, which has two parts: each sample's decode error e, which
  the codec fixes exactly, and the compression of arrival spans against send spans, which depends on the player's
  real network, unknown to Lync. `windowSeconds` sets how long sustained excess speed may run before the anchor sees it.
- **Options:** (a) R35's defaults, `tolerance` derived from `v5.md` §9's simulated network and `windowSeconds` 10 s, chosen
  `[refusals-rejudged-4 R35]`; (b) **both required**, with the derivation in the docs.
- **Choice: (b).** A default from a network model is a threshold Lync would be guessing for every game, which the
  rule "Lync does only what it can do exactly" gives to the developer; `maxDistance`, `tolerance` and `total` are
  required for the same reason.
- **The docs' derivation:** `tolerance` = `perSecond` × c + 2e. On `v5.md` §9's model, c = jitter range + client flush +
  server step = 0.02 + 1/60 + 1/60 = 0.0533 s on the unreliable lane, plus the definition's `limit.slackSeconds` (2 s by
  default, `v5.md` §3.4) on the reliable lane: 2.0533 s. e = √3 · step/2 for `t.vector3` (√2 · step/2 with `"xz"`),
  step/2 for `t.number`, π/n for `t.angle`, the octahedral error for `t.direction` (0.2369° at 10 bits), 0 for `t.int`
  and `t.f64`; `t.f32` and `t.vector3f32` err by 2^−24 of the value, so their e is 2^−24 × the largest magnitude the
  game sends (R35's e, 2^−24 × the largest magnitude the codec admits, is about 2 × 10^31 for an unbounded `t.f32`). At
  16 studs/s and `t.vector3` step 1/32 this gives 0.907 studs unreliable and 32.907 reliable.

Checked against the simulation (`perSecond` 16 studs/s, step 1/32, 3 × 10^6 messages per line,
`refusals-rejudged/r4_maxrate.out`); the model sends each sample in the frame it is taken, so its needs sit at least
`perSecond`/60 = 0.27 studs below the derivation, which covers a flush up to 1/60 s after the sample:

| Lane and network | Smallest `tolerance` with no failure | The docs' derivation |
|---|---|---|
| unreliable, jitter 0.02 s, 5% loss | 0.309 studs | 0.907 |
| unreliable, jitter 0.05 s (673,080 late frames) | 0.576 | 0.907 (derived at 0.02 s) |
| reliable, jitter 0.02 s | 0.309 | 32.907 |
| reliable, 0.85 s stalls at 1/600 per frame | 13.408 | 32.907 |

### 6.3 What it bounds, and how it is defeated

- A forged sequence of values stays within `perSecond` × elapsed + `tolerance` of the previous sample and of the anchor; the
  excess speed it can sustain unseen is `tolerance`/`windowSeconds`: 0.091 studs/s (0.57% of 16 studs/s) at `tolerance` 0.907
  and `windowSeconds` 10 s.
- A client that withholds messages for T seconds may then move `perSecond` × T + `tolerance`: the server can't know where it
  was in between, so that is the bound.
- Defeated by moving at `perSecond` exactly, and by any client physics change `perSecond` allows. It bounds only what
  the client claims in Lync payloads, never engine-replicated characters; a game with server truth compares against it
  with `within`.
- **`planar` on `within`** needs no option: a reference returning `Vector3.new(r.X, v.Y, r.Z)`, v being the claim,
  makes `within`'s distance the XZ distance, exactly equal in f32 arithmetic in 10^6 of 10^6 random pairs
  (`refusals-rejudged/r4_cooldown.out`). The docs give the line. `maxRate` needs `plane` because its references are
  Lync's state, which game code can't reach.

### 6.4 Known causes on an unmodified client

1. **Game-applied motion:** teleports, respawns, seats, vehicles, knockback, conveyors. Call `resetChecks` with
   `exemptSeconds` (§1.6) where the game moves the player.
2. **Falling and jumping** with `plane = "xyz"`: a falling character's vertical speed grows under `Workspace.Gravity`
   (196.2 studs/s² by default), so it passes a walking `perSecond` about `perSecond`/196.2 s into a fall. Ground
   movement uses `"xz"`, as Roblox's movement-validation guidance says (documented, creator-docs
   `scripting/security/network-ownership.md`).
3. **A server step longer than 1/60 s** (a hitch), or a reliable stall longer than 2 s, compresses arrival spans by
   its length; evidence `spanSeconds` shows it.
4. **Network jitter above the c the developer's `tolerance` covers** (mobile jitter unmeasured, §11), and a speed boost
   above `perSecond`.

### 6.5 Options and cost

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `perSecond` | number (real) | the field's unit per second | > 0, finite | required | none |
| `tolerance` | number (real) | the field's unit | ≥ 0, finite | required (§6.2; the docs' derivation) | none |
| `windowSeconds` | number (real) | s | 0.1–3600 | required (§6.2) | none; unseen excess speed is `tolerance`/`windowSeconds`, so a larger window lets less through |
| `plane` | `"xyz" \| "xz"` | — | `"xz"` only for `t.vector3` and `t.vector3f32` (else `callOptionOutOfRange`) | `"xyz"` (the codec's own metric, as in `within`) | none; `"xz"` is 3–11 ns cheaper native (`r4_maxrate.out`) |
| `policy` | `"drop" \| "deliver"` | — | — | required | none |

Measured, net (`refusals-rejudged/r4_maxrate.out`, 3 runs, best of 7): 84–85 ns native and 318–330 ns interpreted per
message in 3-D; 74–82 ns native and 299–305 ns interpreted with `"xz"`. State 80 B per player per check; wire 0 B.

**`cooldown`** stays out: a cooldown of s seconds is `limit = { perSecond = 1/s, burst = 1 }` (`v5.md` §5.4). The
client never sends two messages less than s apart; the server admits at most 1 + (T + 2)/s over any T seconds
(`refusals-rejudged/r4_cooldown.out`: after idle, 5 at once at s = 0.5 s, 3 at 1 s; for s > 2 s a second only s − 2 s
after the first). A stricter arrival-gap test would need the same `limit.slackSeconds`, so a second limiter would add
nothing, and principle 4 refuses it.

## 7. Claims

### 7.1 The markers `:claim()` and `:input()`

Two codec methods in the shared schema, non-generic and returning the same codec type (`v5.md` §3.3's rule):
`t.int(1, 2 ^ 40):claim()`, `t.string(200):input()` `[checks-telemetry C4]`.
- **Roles.** A leaf is an *input* (the client's own control or choice) or a *claim* (what the client asserts about the
  world: a hit target, a shot origin, an amount gained, a completion time) `[anticheat-design §3.2]`. A leaf's role is
  the nearest marker on it or on a codec enclosing it within the payload; unmarked leaves are inputs. So
  `{ … }:claim()` marks a whole record, and an inner `:input()` overrides it for its own leaves.
- **Placement.** Markers are allowed only in client-sent payloads: `data` of `from = "client"` events and requests
  and of streams (`Lync.stream`), and `reply` of `from = "server"` requests (`v5.md` §3.3). Anywhere else (server-sent
  `data`, a client request's `reply`, collection fields) is the declaration error `roleMarkerMisplaced` at the
  definition's line. A stream's claim leaves are verified per index at playout, and its `connect` is the handler the
  requirement (§7.3) refuses (`v5-collections.md` §15.4).
- **Decision: hashing.** (a) Not hashed, an exception to "every value in the schema goes into the schema hash"
  (`v5.md` §3.4); (b) **hashed as a wrapper codec**, type 26 `role`: role u8 (1 input, 2 claim), then the codec
  (`v5.md` §4.7). Choice: (b): no exception, 2 B of hash input per marker, nothing at run time. A changed role gives
  `MISMATCH` between builds, which never meet in production because both shards come from one build run.
- **Types:** unchanged; a marker doesn't change `T`.
- **`:input()`** has one effect: it silences `freeFormRoleMissing` on a free-form leaf (§7.4). Draft 3.5 dropped it (M4:
  unmarked fields are inputs already); it returns because the lint needs a way, on the field's own line, to record
  that a free-form leaf was looked at and is an input, and an unmarked leaf can't say that.

| Marker | Placement | Default | Cost |
|---|---|---|---|
| `:claim()` | any codec in a client-sent payload | unmarked leaves are inputs | 0 B wire; 2 B hash input; nothing per message; a verifier per claim leaf of `data` before its handler (§7.2, §7.3) |
| `:input()` | as `:claim()` | — | 0 B wire; 2 B hash input; no run-time effect |

### 7.2 Decision: what verifies a claim

- **Problem.** The marker is only protection if the server must verify each claim before game code acts on it.
  Lync can't judge whether a verifier is sufficient: a validator returning `true` unconditionally looks like any
  other.
- **Options:** (a) only `validate` verifies (draft 3.5); (b) `validate`, or a `within`, `monotonic` or `maxTotal` on
  the leaf `[checks-telemetry C4]`; (c) `validate`, or **any check, `derive` included,** on the leaf
  `[server-facts §U9.9, Impl6]`.
- **Choice: (c).** The requirement records that the server declared a verification for the leaf, not that it
  suffices, so choosing which kinds count would be Lync judging sufficiency. (a) makes a game write an empty
  validator beside a check that already verifies. (b) leaves out the one kind built for claims.
- **The rule.** A claim leaf of `data` is *verified* when the definition has a validator, or when at least one check
  of any kind and any policy is declared on that leaf's field handle (checks take leaf codecs only, so no record's
  handle carries one). A `"deliver"` check counts: its failures are reported, and the policy is the developer's.
  Leaves inside arrays, maps and union variants, and leaves of codecs no check takes (strings, instances), are
  verified only by a validator. No other declaration verifies (`refers`, `reactsTo`, `challengeAnswer`, telemetry;
  `v5.md` §3.3). No declaration can be removed, so a leaf once verified stays verified.
- **Replies** of server requests may carry markers, for the lint only; answers have no validator step.

### 7.3 The claim requirement

The decision is `v5.md` §3.3's ("Decision: claims"), which the core-api unit owns; this file states what it means
for checks.
- **Rule.** On the server view, `connect` or `handle` on a definition whose `data` holds an unverified claim leaf
  (§7.2) throws the caller error `claimUnverified` at that call:
  `[Lync] claimUnverified: arena.strike:connect data.target must have a validator or a check, got none`. No message
  is dropped for it, and nothing is counted: the requirement costs nothing per message.
- **Why at the handler** (`v5.md` §3.3): a drop of canonical messages for what the game forgot to declare would be
  Lync acting on input, and delivering them would let the marker guarantee nothing. Refusing the handler acts on no
  input and names the line to change; its only cost is an order, verifiers before the handler. Messages decoded
  before a handler exists reach no handler and are counted in `messagesUnhandled` (`v5.md` §3.5).
- **What it guarantees, exactly** (review M1): no message holding a claim leaf reaches `connect` or `handle` unless a
  validator ran on it, or each check declared on the leaf either was evaluated on it, or skipped it in one of three
  counted ways: its game function returned nil (`checksSkipped`), `messagesPerCheck` didn't draw it (`checksUndrawn`),
  or it fell in a `resetChecks` window (`checksExempted`). A developer who needs every claim evaluated gives the
  definition a validator, or a reference that never returns nil, `messagesPerCheck` 1 and no window on that check. It is
  defeated by a validator that returns `true` unconditionally, and by marking a claim `:input()` to silence the lint.

```luau
-- shared schema
strike = Lync.event({ from = "client", lane = "unreliable", data = {
	target = t.int(1, 2 ^ 40):claim(), origin = t.vector3(-2048, 2048, 1 / 32):claim(), aim = t.direction(11),
} }),
-- server: verifiers first, then the handler
Net.strike.fields.origin:within({ reference = rootOf, maxDistance = 6, policy = "drop" })
Net.strike.fields.target:refers(Net.fighters) -- v5-integrity.md §8
Net.strike:validate(function(player, s) return Fighters.alive(s.target) end)
Net.strike:connect(onStrike)
```

### 7.4 The `freeFormRoleMissing` lint

The rule, its evidence, severity option and channel are the `freeFormRoleMissing` row of `v5-tooling.md` §3.4: a
free-form leaf (unbounded floats and integers, more codes per component than `check.minFreeFormCodes`, 65,536 by default,
strings, buffers, instances, custom codecs) in a client-sent payload with no role marker on itself or an enclosing
codec. Its relation to this file:
- **It is what makes the marker protect.** A flagged leaf gets `:claim()`, and then §7.2 requires a server
  verifier; or it gets `:input()`, which records the decision on the field's line.
- **Measured on stand-in codecs** (`checks-telemetry/lint_freeform.out`): `v5.md` §3.4's `arena` gives 2 warnings,
  `chat data` (an input: `:input()`) and `strike data.target` (a claim: `:claim()` and a verifier), and 0 with those
  markers. A demo set gives 7: four claims (`collect.coins`, `hit.damage`, `hit.origin`, `hit.part`) and three inputs
  (`settings.volume`, `settings.name`, `confirm reply.note`).
- **What it misses, by design:** outcomes in input-shaped codecs (`t.bool` wins, `t.int(1, 12)` placings,
  `t.int(1, 500)` amounts), a `t.number(0, 600, 0.01)` completion time (60,001 codes), small ids, and choices among
  a server-provided set. The rule is syntax; it can't recognise outcomes `[anticheat-design §3.2]`.
- **Threshold: the developer's** (scope audit H1). The trigger is exact (a code count), but the number is a proxy
  for "could be a claim", and which fields need a marker is the developer's decision. So it is a `[check]` option,
  `check.minFreeFormCodes` (integer, codes per component, 2–2^53, default 65,536, chosen: below it are every input of
  `v5.md` §3.4 and the demo inputs, 255-code sticks, enums and slot indices; above it ids, currency up to 10^6 and
  fine positions; a measured count of false positives and misses over real schemas would change it; cost none at
  run time). The row and the option are `v5-tooling.md`'s.
- On the runtime path the planner computes it and drops it: there is no build to report to, and a line in every
  session is the channel M11 refused.

## 8. Telemetry

Telemetry keeps per-player copies of values the game already sends, and hands them to game code. It raises no fact
and computes nothing about them.

### 8.1 Decision: where telemetry is declared

- **Options:** (a) codec methods in the shared schema (`t.direction(11):aim()`) `[anticheat-design §5.2]`;
  (b) **calls on the server view**, as checks (§1.1).
- **Choice: (b)** `[checks-telemetry T1]`. Sampling changes no bytes, so it stays out of the hash and a retune needs
  no client rebuild; the server shard is never replicated, so a modified client can't read which fields are sampled;
  nothing the client must see depends on it.
- **Scope:** `data` of client-sent events and client requests' asks, on the server (streams, which checks also take,
  are not sampled); elsewhere `declarationMisplaced`. A sampled field is named by its handle in `fields` (§1.2:
  `fieldPathUnknown`, `fieldCodecUnsupported`); `atom`'s
  `fields` are path strings, typed as unions of the paths it accepts (`v5.md` §3.4). Declared at any time; applies
  to frames decoded after the call.

### 8.2 Rings and their entries

Each declaration keeps one ring per player of `maxEntries` entries; one ring per definition, so a definition names its
ring (a second `aim` or `series`, on the definition or any of its fields, throws `telemetryDuplicate`).
- **Timing** (`Net.<def>:series(options?)`): one entry per frame carrying a delivered message of the definition.
- **Values** (`Net.<def>.fields[path]:series(options?)`): the same, plus the field's value. Scalars (`t.int`,
  `t.number`, `t.f32`, `t.f64`, `t.angle`, `t.bool` as 0 or 1, a list enum's 0-based index, a Roblox enum item's
  `Value`) are stored as the nearest f32, so integers above 2^24 lose precision; vectors (`t.vector3`, `t.vector3f32`,
  `t.direction`) as three f32. Lync stores values; differences are the analyst's.
- **Aim** (`Net.<def>.fields[path]:aim(options?)`): the field's look direction as yaw and pitch. Each aim codec gives
  a unit direction (x, y, z): `t.direction` itself; `t.rotation` and `t.cframe` their `LookVector`; a record
  `{ yaw = t.angle(…), pitch = t.angle(…) }` the vector (−sin yaw · cos pitch, sin pitch, −cos yaw · cos pitch).
  Then yaw = atan2(−x, −z) (0 looks along −Z) and pitch = asin(clamp(y, −1, 1)), quantized to
  yawCode = ⌊(yaw + π) · 65536/2π + 0.5⌋ mod 65536 (0.0055° a step) and pitchCode = ⌊(pitch + π/2) · 65535/π + 0.5⌋
  (0.0027°). Pitch and yaw are the two inputs published aim detectors take `[anticheat-design §5.1]`, and one format
  serves every aim codec.

**Entry layout** (little-endian; ring entries and exported entries are byte-identical, so atoms copy them with
`buffer.copy`):

| Bytes | Field | Meaning |
|---|---|---|
| 0–3 | `clockMilliseconds` u32 | ⌊`os.clock()` × 1000⌋ mod 2^32 when Lync received the frame (server arrival, never client time, R20) |
| 4–7 | `frameKey` u32 | the frame key (§3.1) mod 2^32 |
| 8–11 | aim: `yaw` u16, `pitch` u16; scalar: f32 | aim and scalar series |
| 8–19 | three f32 | vector series |

Entry sizes: timing 8 B, aim 12 B, scalar 12 B, vector 20 B. The research's layout had u16 `clockMilliseconds` and
`frameKey` `[checks-telemetry T1]`; with them, a ring of a definition sent less often than once per second spans more than the
65.536 s wrap, its times alias, and the window search (§8.4) is no longer sorted. u32 fields are exact while a ring
spans less than 24.8 days (2^31 ms, the reach of the signed 32-bit differences of §8.4; `frameKey` wraps after 414 days at
120 frames/s), for 4 B more per entry.

**Decision: one entry per frame.** A frame's messages share one arrival time, so Lync samples the last delivered
message of the definition in each frame (messages are in call order, `v5.md` §4.1): more entries would add values
with no time between them, and one per frame bounds a ring's turnover by its definition's lane budget (a definition
uses one lane: at the defaults 60 frames/s reliable or 120 unreliable, plus a burst of 240, `v5.md` §7.5). At 60
frames/s a 64-entry ring holds 1.07 s.

### 8.3 Where it runs

**Step 6b, sample** (§1.4), after the checks' commit and before delivery, on *delivered* messages (`v5.md` §3.5): those
that pass step 6 and whose definition has a handler at step 7, with the values game code receives. An accepted message
with no handler (`messagesUnhandled`) is not sampled, though checks commit on it (§1.4). Dropped messages are not
sampled: each drop is already a fact or a counter (`limitExceeded`, §1.5's check facts, `validatorsReturnedFalse`), and
sampling them would make a second record of one event. It runs in the pipeline loop, not in a handler thread, so a
yielding handler can't delay it. `clockMilliseconds` and `frameKey` are read once per frame.

### 8.4 Atoms

`Net.<def>:atom({ beforeSeconds, afterSeconds, fields, series, maxPending })`: a fixed record taken when a message of
the definition is delivered, with a window of another definition's stream around it. One atom declaration per definition
(a second throws `telemetryDuplicate`).
1. **Trigger** (step 6b). When at least one `Lync.telemetry.observeAtoms` connection exists and the player has a free
   pending slot, Lync copies the header and the `fields` values (as f64, a vector as x, y, z) into the slot, due at
   `os.clock()` + `afterSeconds`. With no free slot it takes nothing and counts `atomsSkipped`; it never evicts. With no
   connection it takes nothing.
2. **Complete**, once per flush, where fact windows are swept (`v5.md` §7.3). For each due atom, Lync binary-searches
   the `series` ring for the first entry whose `clockMilliseconds` is no older than the trigger's `clockMilliseconds`
   − 1000 × `beforeSeconds` (u32
   differences, exact by §8.2), and copies it and every newer entry into the player's batch buffer.
3. **Hand off** (§8.5).

**Atom format, version 1:** `serverTime` f64 (`GetServerTimeNow()` at the trigger frame), `clockMilliseconds` u32 and
`frameKey` u32 of the trigger frame, `entryCount` u16 (entries copied, n; at most `maxEntries`, 1024), `flags` u8, the field
values as f64 in declaration order, then n entries. Size = 19 + 8 · F + n · E, with F the field values and E the entry
size: 591 B for 4 values (`origin` x, y, z and `target`) and 45 aim entries. **Flags** record what happened to the
copy and the message, each with an exact condition:
- bit 0: a check with `policy = "deliver"` failed on the trigger message (its §1.5 fact occurrence exists);
- bit 1: truncated: the ring's oldest entry is newer than the trigger's `clockMilliseconds` − 1000 × `beforeSeconds`;
- bit 2: partial: the player left before `afterSeconds` elapsed, so the atom completed at the leave.

The research's clamp bit is gone with `clamp` (§1.3). An entry's time relative to the trigger is
(entry.`clockMilliseconds` − atom.`clockMilliseconds`) as a signed 32-bit difference, in milliseconds.

### 8.5 Decision: how samples reach game code

| Option | Cost | Memory | Fit |
|---|---|---|---|
| (a) a callback per atom | a frozen table and a pooled-thread resume per atom: 259 ns native to build, 88–131 ns to resume `[diagnostics §5.1, §9]` | none held | one HTTP request per atom would pass 500 requests/min per server at 8.3 atoms/s |
| (b) **batches pushed to a callback** | 0.66–0.71 µs per batch of 16, plus one resume per connection (measured) | at most `telemetry.atomsPerBatch` atoms per (player, definition) | matches the export unit; bounded |
| (c) pull | a copy per call | atoms held until game code asks: unbounded, or dropped unseen | right for rings, wrong for atoms |

- **Choice: (b) for atoms, (c) for rings** `[checks-telemetry T2]`. Atoms are events with a moment and a fixed size,
  so bounded pushed batches keep memory bounded and give game code its export unit. A ring filled at 60 Hz × 12 B is
  720 B/s per player, 72 KB/s at 100 players; pushing it would hand game code all of it with no moment to cut at, so
  game code copies a ring when it decides to (a report filed, a round ended).
- **Batch close:** at `telemetry.atomsPerBatch` atoms; at `telemetry.maxBatchSeconds` after the batch's first atom
  (checked once per flush); when the player leaves (pending atoms complete as partial first; `v5.md` §5.1 flushes the
  leaving player's frame before); at `BindToClose`, for every open batch. Game code that exports must finish its HTTP
  within the shutdown window, which is Roblox's limit.
- **Delivery rules**, as observers (`v5.md` §7.3): each connection is called in a pooled thread, so a throwing
  callback is reported natively and a yielding one holds only itself; the batch table and its format are frozen;
  each connection receives its own copy of the buffer, which it owns, may keep and may send.
- **Rings:** `Lync.telemetry.read(player, Net.look)` returns a copy of the ring, oldest first, with the anchor
  `serverTime` (`GetServerTimeNow()` at the call) and `clockMilliseconds` (⌊`os.clock()` × 1000⌋ mod 2^32 at the
  call), so an entry's server time is `serverTime` − ((`clockMilliseconds` − entry.`clockMilliseconds`) mod
  2^32)/1000; nil when the player has no ring. One
  buffer copy of at most `maxEntries` × E bytes.
- **Counters** (`v5.md` §7.4): `atomsDelivered` and `atomsSkipped`, per definition. Atoms raise no fact: an atom has
  no trigger beyond "a message arrived".

### 8.6 API and types

```luau
-- server
Net.look.fields.dir:aim()                             -- look: from = "client", data = { dir = t.direction(11) }
Net.strike:series()                                   -- timing only
Net.strike:atom({ beforeSeconds = 0.5, afterSeconds = 0.25, fields = { "origin", "target" }, series = Net.look })
local connection = Lync.telemetry.observeAtoms(function(batch: Lync.AtomBatch)
	Export.queue(batch.player, batch.definition, batch.data) -- game code (§8.8)
end)
local look = Lync.telemetry.read(player, Net.look)    -- a copy of the ring, or nil
```

Types are plain records with no `read` modifiers, since the old solver rejects them in generated shards (`v5.md`
§3.2); the tables are frozen at run time (the format and its `fields` too). `aim` and `series` are methods of the
handles whose codec they take (`v5.md` §3.4: a handle's type comes from its field's codec); `atom`'s `fields` is
typed as a union of the definition's numeric paths.

```luau
export type AtomBatch = {
	player: Player,
	namespace: string,
	definition: string,
	atomCount: number,   -- atoms in data
	format: AtomFormat,  -- one per atom declaration
	data: buffer,        -- atomCount atoms, format version 1
}
export type AtomFormat = {
	version: number,     -- 1
	fields: { string },  -- value names in order: "origin.x", "origin.y", "origin.z", "target"
	entry: "timing" | "aim" | "scalar" | "vector" | "none",
	entryBytes: number,  -- 8, 12, 12, 20 or 0
}
export type RingCopy = { format: AtomFormat, entryCount: number, data: buffer, serverTime: number, clockMilliseconds: number }
export type AtomSample = { sinceTriggerSeconds: number, frameKey: number, yaw: number?, pitch: number?, value: number?, vector: vector? }
export type Atom = { serverTime: number, frameKey: number, flags: number, fields: { [string]: number }, samples: { AtomSample } }
```

`Lync.telemetry.decode(batch): { Atom }` turns a batch into tables (`sinceTriggerSeconds` negative for entries
before the trigger) for game code that analyses in process; a cold path that allocates per atom. roblox-ts, from the same IR (dot calls, `this: void`, `readonly`
fields):

```ts
interface ServerEvent<T> {
	series(this: void, options?: { maxEntries?: number }): void; // timing only
	atom(this: void, options: { beforeSeconds: number; afterSeconds: number; fields?: ReadonlyArray<NumericPath<T>>;
		series?: TelemetrySource; maxPending?: number }): void;
}
// the server views of client-sent events and client requests (review m10; type names provisional, `v5.md` §3.6)
type TelemetrySource = ServerEvent<unknown> | ServerRequest<unknown, unknown>;
// the handle interface of a t.direction field (`v5.md` §3.6); every aim codec's handle has `aim`, every value
// codec's `series`
interface DirectionField<D> {
	aim(this: void, options?: { maxEntries?: number }): void;
	series(this: void, options?: { maxEntries?: number }): void;
}
declare namespace telemetry {
	function observeAtoms(this: void, fn: (batch: AtomBatch) => void): Connection;
	function read(this: void, player: Player, def: TelemetrySource): RingCopy | undefined;
	function decode(this: void, batch: AtomBatch): ReadonlyArray<Atom>;
}
```

`NumericPath<T>` is emitted per definition as a literal union, never computed by type-level recursion. Caller
errors: `fieldPathUnknown`, `fieldCodecUnsupported` (the codec isn't one the call takes, where types don't catch it),
`telemetryDuplicate`, `atomSeriesMissing` (`series =` a definition with neither an `aim` nor a `series`),
`declarationMisplaced`, and the option codes of §10.

### 8.7 What Lync does not do

Each follows "Lync reports facts" (R23) and "no automatic consequence" (R22, R24):
- **No statistics, scores, thresholds or models.** The research's online mean and variance
  `[anticheat-design §5.2]` are dropped: a summary Lync chooses is the first step of a verdict, and raw samples cost
  as little to keep. Means, deltas, angular speed, reaction times and models belong to game code or offline tools.
- **No fact from a telemetry value**, and no flag meaning anything but its exact condition (§8.4).
- **No consequence.** Sampling never changes what is delivered, and nothing in telemetry drops, delays, throttles or
  tags a player.
- **No export, storage or transport.** Lync makes no HTTP request, writes no DataStore and holds no secret, as
  diagnostics export is a recipe `[diagnostics §5.4]`. Game code owns the 500 HTTP requests/min per server, the
  "Allow HTTP Requests" setting (documented, creator-docs `cloud-services/http-service.md`) and the legal obligations
  (§8.11).
- **No id added by Lync, and no client text.** A batch carries the `Player`; Lync writes no id into the buffer.
  `fields` and value series are copied as decoded, so a field that holds an id puts that id in the buffer: in the
  §8.6 example, `strike.target` is a `fighters` key, which `v5.md` §3.4's example sets to a `UserId`, so every atom
  holds the struck player's id (review M5). Atoms and series take numeric codecs only, so a batch can't carry chat
  or any other text a player typed.

### 8.8 The export recipe (docs)

One `Lync.telemetry.observeAtoms` connection appends each batch to a buffer behind a header the recipe fixes (version
u8, namespace and definition as u16-length strings, the exported player key as f64, count u16), and sends the buffer
every 2 s with one `HttpService:RequestAsync` whose `Body` is `buffer.tostring(…)` (a body "can be any string, including
binary data", documented, `HttpService.yaml`), retrying with backoff (documented best practice).
- At 100 players × 2 atoms/s × 591 B, that is 118 KB/s: 30 requests/min of 236 KB each (derived).
- A request body limit is not documented (`HttpService.yaml` and `http-service.md` searched for "size", "limit",
  "MB", "body"): unverified (§11). The recipe takes a byte limit as a parameter and splits the buffer at it.
- `PostAsync`'s `compress` argument gzips the body (documented); `EncodingService`'s Zstd is the other route.

### 8.9 Known causes in the samples of an unmodified client

`checks-telemetry/telemetry_samples_accum.out` (draft 3.6, review m7): the research's model rerun with `v5.md` §5.1's
pinned accumulator as the flush rule (`telemetry_samples_accum.luau`; luau 0.740, seed 742); `v5.md` §9's network,
frame times drawn per case, not measured on devices.

| Case | Flushes/s | Server inter-arrival, mean ± sd (ms) | p1–p99 (ms) | Aim entries per 0.75 s window, min / mean / max | Largest gap in a window (ms) |
|---|---|---|---|---|---|
| 30 FPS, low-end mobile | 29.2 | 35.9 ± 12.5 | 16.1–78.6 | 16 / 20.8 / 24 | 142.6 |
| 45 FPS, GPU-bound | 44.0 | 23.9 ± 10.4 | 4.6–55.9 | 24 / 31.4 / 36 | 117.1 |
| 60 FPS cap, steady | 60.0 | 17.6 ± 9.0 | 0.7–41.8 | 36 / 42.8 / 46 | 73.4 |
| 60 FPS cap, 3% spikes | 58.3 | 18.1 ± 9.5 | 0.7–45.1 | 34 / 41.5 / 46 | 85.2 |
| 120 FPS cap | 60.0 | 17.5 ± 9.1 | 0.6–41.5 | 35 / 42.7 / 47 | 80.2 |
| 144 FPS cap | 60.0 | 17.6 ± 9.4 | 0.6–42.6 | 37 / 42.7 / 46 | 69.2 |
| 240 FPS cap | 60.0 | 17.5 ± 9.0 | 0.6–41.7 | 36 / 42.8 / 46 | 79.6 |

The docs state each cause, so analysis doesn't read them as anything else:
1. **Frame rate sets the sample rate** (29–60 Hz across devices), so analysis by index is wrong on every device;
   every entry carries its time and atoms their `entryCount`.
2. **The network dominates timing:** server-side sd 9.0–12.5 ms against client flush sd 0.2–5.6 ms; a timing series
   resolves a hand only at intervals well above 20 ms.
3. **Game code produces machine-regular timing:** a script firing "if now − last ≥ 0.1" sends at intervals fixed by
   its frame grid (at a steady 60 FPS only 100, 101, 116 and 117 ms; seen at the server as 108.1 ± 11.5 ms).
   Automatic weapons, auto-collect and cooldown loops give the same low variance.
4. **Loss and late frames:** 5% loss leaves gaps of 69–143 ms in a window; in arrival order 1.41% of aim deltas run
   backwards at 0.02 s jitter (21.7% at 0.05 s), in key order none. Analysis sorts by `frameKey`.
5. **Yaw near the poles:** one `t.direction(10)` step moves yaw by up to 0.24° level, 1.4° at 80° pitch, 13.6° at
   89°, 180° at 89.9°. Analysis uses the angle between reconstructed directions, never yaw differences; the docs
   give the formula.
6. **Input devices** (unverified, general behaviour): gamepad sticks turn at a rate; touch moves in swipes; mouse
   flicks stop sharply; VR follows the head. No single rule tells them from automation.
7. **The game's own camera code:** lock-on, aim assist, aim-down-sights snaps, recoil, shift-lock, respawn and
   teleport resets, cutscenes, seats.
8. **Quantization:** the aim codec's error (0.2369° at `t.direction(10)`) is far above the export's 0.0055°.
9. **Truncated and partial atoms:** truncated after join, or when frames of the series definition exceed
   `maxEntries`/(`beforeSeconds` + `afterSeconds`) per second (85.3 at `maxEntries` 64 with a 0.75 s window); partial on
   leave.
10. **Server load:** arrival time is when Lync's handler runs, so a server frame hitch stamps several frames with
    nearly one time (magnitude unverified, §11).

**How it is defeated.** A modified client controls every value it sends and when; it can shape aim and timing like
any device. Telemetry raises the cost of crude automation and gives evidence for review; it proves nothing about one
player.

### 8.10 Options, memory and cost

| Option | Where | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|---|
| field | `fields[path]:aim` | field handle | — | a `t.direction`, `t.rotation`, `t.cframe` or `{ yaw = t.angle, pitch = t.angle }` field | — | 65–73 ns native, 221–228 ns interpreted per sampled frame from a decoded direction; the record form adds four trigonometric calls (unmeasured) |
| field | `fields[path]:series`, or `series` on the definition for timing only | field handle or none | — | a codec of §8.2's values | none: timing only | timing: 22–24 ns native, 91–93 ns interpreted per sampled frame; values: unmeasured (§11) |
| `maxEntries` | `aim`, `series` | integer | entries | 16–1024 | 64 (chosen: a capacity, 1.07 s of entries at 60 frames/s; a window of `beforeSeconds` + `afterSeconds` truncates above `maxEntries`/(`beforeSeconds` + `afterSeconds`) frames/s, 85.3 for 0.75 s) | E × `maxEntries` per player: 768 B for aim at 64 |
| `beforeSeconds` | `atom` | number (real) | s | 0–2 | required (scope audit F1: the window is the analyst's choice; the docs cite VACnet's reported 0.5 s `[anticheat-design §5.1]` as an example) | needs `maxEntries` ≥ (`beforeSeconds` + `afterSeconds`) × the series' frames per second, else bit 1 |
| `afterSeconds` | `atom` | number (real) | s | 0–1 | required (as `beforeSeconds`; VACnet's 0.25 s is the docs' example) | a pending slot held `afterSeconds` s plus up to one server frame |
| `fields` | `atom` | array of string | — | paths of §8.2's value codecs on the atom's definition, at most 16 values (a vector counts 3) | `{}` | 8 B per value per atom; trigger 35–38 ns native, 151–163 ns interpreted for 5 values |
| `series` | `atom` | a definition with an `aim` or a `series` | — | — | nil: no entries | completion 252–260 ns native, 477–506 ns interpreted per atom of 46 entries |
| `maxPending` | `atom` | integer | atoms per player | 1–64 | 8 (chosen, a capacity: sustains 8/(`afterSeconds` + 1/60 s) atoms/s per player, 30 at `afterSeconds` 0.25 s; a definition firing faster needs more) | (19 + 8 · F) B each |
| `telemetry.atomsPerBatch` | `Lync.configure` | integer | atoms | 1–256 | 16 (chosen: the hand-off is 41–44 ns per atom amortised at 16; a larger batch holds more memory per player) | at most `atomsPerBatch` × the atom size held per (player, definition); 0.66–0.71 µs per hand-off plus 88–131 ns per connection |
| `telemetry.maxBatchSeconds` | `Lync.configure` | number (real) | s | 1–600 | 30 (chosen; at or below `observe.windowSeconds`, an atom reaches game code no later than a coalesced fact of its message) | an open batch is held up to this long |

- **Memory per player** (derived from the layouts): aim ring 768 B, timing ring 512 B, vector ring 1,280 B at 64;
  pending 8 × 51 B = 408 B for 4 values; batch buffer 16 × 591 B = 9.5 KB for 45-entry windows, at most
  16 × (51 + 64 × 12) = 13.1 KB. One aim series, one timing series and one atom declaration: at most 14.8 KB per
  player, 1.48 MB for 100 players. Allocated at the player's first sampled message, freed on leave.
- **Cost** (measured on the research's 4 B and 8 B layouts, `checks-telemetry/telemetry_cost.out`; the widened
  fields of §8.2 are the same number of buffer writes and copy 4 B more per entry, unmeasured): 100 players at 60 aim
  samples/s is 0.39–0.44 ms/s native and 1.3 ms/s interpreted; two atoms per player per second add 0.06 ms/s native
  and 0.13 ms/s interpreted, the batches about 0.01 ms/s. Wire 0 B: Lync samples traffic the game already sends (an
  aim series needs the game to send its look direction, 22 bits per message for `t.direction(11)` plus framing).
- **Not sampled:** server-sent traffic, anything on the client, and `Player:GetCameraState()` (server-side camera
  under Server Authority, documented), which isn't traffic Lync decodes.

### 8.11 What Lync's docs must tell developers about Roblox's terms

One page, linked from the telemetry reference, quoting each source `[checks-telemetry T3]` (read 2026-10-15; the
readings are the research's, unverified, and not legal advice):
- **Sources it quotes:** the current Creator Terms §14.b (Experience Data), §14.c (User PII), §14.d; the Creator Terms
  in force from 2026-11-01, §3.9 (Game data) and §5.4 (personal information); the Privacy and Cookie Policy's
  definition of personal information; the Community Standards' three lines under "Advertising Integrations" (the ban
  on "programmatic calls to third-party advertising and measurement services", the bar on sharing "personally
  identifiable user engagement information with advertisers", and the prohibition on "creating personalized activity
  profiles of users"); `RTBF-and-creators.md`, `automate-right-to-erasure.md` and `players/users.md`. Until
  2026-11-01 the page cites both versions of the Creator Terms.
- **What it says:**
  - exported telemetry is personal data under the Privacy Policy; Lync adds no id, but the key game code adds makes
    it personal, and an atom's `fields` may already hold other players' ids (a collection key such as
    `strike.target`, §8.7);
  - use it for the purposes the terms name: security, fraud prevention, improving the game;
  - send it to systems you control, over HTTPS (the only scheme `HttpService` allows), with credentials in Secrets;
  - never to advertising or measurement services; sending it to any other third party is restricted (current §14.b,
    §5.4 from 2026-11-01): read the clause and decide; Lync can't decide it for you;
  - don't sell or share it, join it to other personal information, or use it to build cross-platform profiles;
    quote §14.c(ii), §5.4 and the Community Standards' activity-profiles line on records about an individual user,
    without interpreting them as permission;
  - protect it from unauthorized access (§14.d, §5.4);
  - set a retention period, and delete a player's telemetry on every erasure request (webhook or daily message),
    keyed by `Player.UserId`, which is domain-scoped for players who first joined after the rollout, so the request's
    id finds it; index exported atoms also by every id their `fields` hold, so a struck player's erasure request
    finds the atoms that name them;
  - Lync never exports, stores or scores telemetry and never acts on it; what the game does with it, and any
    consequence for a player, is the game's decision;
  - privacy law (the RTBF page names GDPR, CCPA, LGPD and PIPA) applies on its own terms; the page is not legal
    advice.
- **Before the page is written** it must also cite three sources the research didn't fetch: rules for users under
  13 on creator-side data, the Creator Analytics Terms the Community Standards cite, and the scoped-id announcement
  the users page links (§11).

## 9. Sealed delivery

### 9.1 What it protects, and the decision against withholding

- **Problem.** A value the server sends before the game makes it visible (next round's layout, a drop table, a timed
  puzzle's answer) is readable on every client from its arrival. Withholding it until the reveal costs the transfer
  time at the reveal: N bytes take N/R, R being the engine's downstream rate for that player (unmeasured, §11).
- **Options:** (a) withhold until the reveal (draft 3.5's recipe, R34's earlier reason); (b) **send it sealed under a
  per-seal 64-bit key and reveal the key** `[refusals-rejudged-1 R34 (a)]`.
- **Choice: (b)**, for the case where the reveal time matters; (a) stays the game's choice. A reveal is 67–79 bits for
  the first 127 seals, then the client decrypts N bytes at 210–231 ns/B interpreted (CLI), so sealing shortens the
  reveal whenever R is below 4.3–4.8 MB/s divided by the device factor (both unmeasured on Roblox).
- **Protects,** before the reveal: the plaintext is not on the client at all, only ciphertext under a key the client
  doesn't hold, so readers of memory, packets and state, and accounts sharing artefacts, face 2^63 expected trials
  to search one seal's key, or 2^(min(64, h) − 1) to recover S (§9.4), which opens every later seal on that server;
  h is the entropy of S's sources, unmeasured (§11, review M7); HalfSipHash with c ≥ 2, d ≥ 4 "is expected to provide
  the maximum PRF security" for its key and output size (documented, the SipHash README). Unlike every measure in
  `v5.md` §6.2, its secret is not on the client before the reveal.
- **Doesn't protect:** anything after the reveal (every client gets the plaintext then, a modified one no sooner);
  the time and count of seals; whatever the server's own behaviour discloses; the length, when `hideLength` is false.
  Only server-side code can defeat it, by revealing early or sending the value elsewhere.

### 9.2 Declaration and API

```luau
-- shared schema
nextRound = Lync.event({ from = "server", data = Layout, sealed = { maxOutstanding = 1 } }),
-- server
local seal = Net.nextRound:fire(Lync.all, layout) -- returns a Seal for a sealed definition
-- … when the round starts
seal:reveal()                                     -- or seal:discard()
-- client: unchanged; the handler runs at the reveal with the decoded value
Net.nextRound:connect(function(layout) end)
```

- **`sealed`** is a definition option of server-sent reliable events, in the shared schema and hashed (the client must
  decrypt). On a client-sent event, a request, a collection or the unreliable lane it is the declaration error
  `definitionOptionMisplaced` (`v5.md` §3.4); a `data` reaching a `t.instance` is `sealedInstanceUnsupported`, since
  instances travel in the frame's instance array in the clear (`v5.md` §4.2) and can't be sealed.
- **`fire`** on a sealed definition returns a `Seal` with `reveal()` and `discard()`; calling either on a seal already
  revealed or discarded throws `sealSettleDuplicate`. Generated path: `fire`'s return type is `Seal` for sealed
  definitions; runtime path: a type function on the `sealed` property of the definition's options type, `Seal` when it
  excludes nil and `Seal?` when it includes nil, checked under the new solver (`v5.md` §3.5). roblox-ts: `fire(this:
  void, target, data): Seal`.
- **Client types** are unchanged: `connect` handlers receive the decoded value at the reveal.

### 9.3 Wire

Each message of a sealed definition is one row, and runs of a sealed definition are always single-row, as request
and control runs are (`v5.md` §4.3; review M6: a sealed row is not a codec, so a column block has nothing to
flatten):

```
sealed row := kind:u2 ( 0 seal:    seal:EG0 blocks:EG0          -- ciphertext: 8 × blocks bytes in the tail
                      | 1 reveal:  seal:EG0 key:u32 key:u32     -- the seal key, low then high
                      | 2 discard: seal:EG0 )
```

- **Plaintext:** the codec's single-row encoding of the value written as its own `bits align tail`, zero-padded to
  8 × `blocks` bytes. `blocks` = ⌈B/8⌉ for the value's B bytes, or ⌈W/8⌉ for the codec's worst-case W bytes when
  `hideLength` is true.
- **Ciphertext** = plaintext XOR keystream; keystream block j (j = 0 … `blocks` − 1) = HalfSipHash-2-4/64 under the
  seal key K_i over (i mod 2^32 as u32le, j as u32le). Sealing and opening are the same operation.
- **Size.** A sealed message's worst case is 8 × ⌈W/8⌉ B of tail plus a header of at most 2 + 107 + the EG-0 length of
  ⌈W/8⌉ bits; `messageBytesExceeded` applies to it. A reveal is 2 bits + the seal id's EG-0 + 64 bits: 67 bits for id 0,
  at most 79 bits for ids below 127 (derived); a discard is 2 bits + the id's EG-0.
- **Encode once.** One key per seal, not per viewer: a seal's chunk and its reveal are identical for every recipient,
  so they are shared chunks and stay eligible for `FireAllClients` (`v5.md` §4.2). Per-player values are separate
  fires.
- **Schema hash:** `sealed` is the last option of `v5.md` §4.7's list, after `ackEveryFrame`: its presence u8 is written
  for every definition, then, when present, `maxOutstanding` `num` and `hideLength` u8. So G6 and G7 changed in draft
  3.6 (`v5.md` §4.10; review m9).

### 9.4 Keys

- **Server secret S** (64 bits), drawn at the server's first sealed send and never sent: S = HalfSipHash-2-4/64
  under the zero key over 24 B, the two `NextInteger(0, 2^32 − 1)` draws (u32le each) of a `Random.new()` instance
  created without a seed and used for nothing else (internal entropy source, documented, creator-docs
  `datatypes/Random.yaml`), then the 16 bytes of the hex digits of `HttpService:GenerateGUID(false)` (a version 4
  random UUID, documented, `HttpService.yaml`; security None). S then has the entropy of the stronger of two
  independent sources, at no wire or per-seal cost (review M7). Neither source documents its entropy (unverified,
  §11). A revealed key is one PRF output under S, not generator state.
- **Seal key** K_i = HalfSipHash-2-4/64 under S over (d as u32le, i as u64le), with d the server's number for the
  definition (sealed definitions numbered from 0 in order of first sealed send) and i the definition's seal counter
  from 0 on this server, which is also the wire `seal` id. Keys are computed at the reveal, so the server stores no
  key.

### 9.5 Recipients and `maxOutstanding`

- **Problem** (review B2). A seal and its reveal must reach a player together or not at all: a reveal naming no held
  seal, or a seal while `maxOutstanding` are held, refuses the client's whole reliable frame (§9.6), and §5.3's join
  hold drops sends past 32,768 B, so it could drop one and keep the other.
- **Recipients** are the players to whom the seal row was queued: the seal's target resolved at the flush that
  encodes it (`v5.md` §3.5), less those skipped for `maxOutstanding` (below) and those whose join hold refused the row
  (`joinHoldBytesExceeded`, `v5.md` §5.3). A refused player is not a recipient and gets no reveal or discard.
- **Outstanding** counts, per (player, definition), seal rows queued to that player whose reveal or discard row has
  not yet been queued to them. A player already at `maxOutstanding` is skipped for that seal, which never reaches them,
  and the server records the local fact `sealsOutstandingExceeded`.
- **`reveal()` and `discard()`** queue the reveal or discard row, in call order, to each recipient still connected;
  called before the seal's own flush, both leave in the same flush after it. A recipient's count falls when its row
  is queued. **Reveal and discard rows are never refused by the join hold's caps**, so a recipient that holds a seal
  always receives its reveal or discard: each row is at most 2 + 107 + 64 bits (22 B), and a player holds at most
  `maxOutstanding` (≤ 256) seals per sealed definition, so the hold can exceed 32,768 B by at most 256 × 22 B = 5,632 B
  per sealed definition (derived). A leaving player's counts are freed.
- **Late joiners.** A player who joins after a seal was queued doesn't receive it (review m6). The recipe: on
  `PlayerAdded`, fire the same value to the joiner, `local s2 = Net.nextRound:fire(player, layout)`, and reveal it
  with the round's seal; a joiner after the reveal gets `Net.nextRound:fire(player, layout):reveal()`, which
  queues seal and reveal in one flush.

### 9.6 Client decode

- The client holds, per sealed definition, at most `maxOutstanding` seals (id → ciphertext).
- **Refused with a `v5.md` §4.8 rule:** `kind` 3 (rule 2); a seal while `maxOutstanding` are held, or `blocks` above
  ⌈W/8⌉ (rule 2); with `hideLength`, `blocks` other than ⌈W/8⌉ (rule 3); a seal id already held, or a reveal or discard
  naming no held seal (rule 7).
- **At the reveal** it decrypts and decodes the plaintext under `v5.md` §4.8 (padding bytes past the encoding must
  be zero, rule 4); a violation refuses the frame holding the reveal. Refusals are counted in `framesMalformed` and sent
  in `REPORT`, as for any downstream frame (`v5-integrity.md` §5). The value is then delivered to `connect` handlers
  at the reveal's place in run order, and the ciphertext is freed; a discard frees it.

### 9.7 Fact, options and cost

| Code | Exact trigger | Action | Evidence | Known causes on an unmodified client |
|---|---|---|---|---|
| `sealsOutstandingExceeded` | local: a sealed send to a recipient already holding `sealed.maxOutstanding` unrevealed seals of that definition | the send to that recipient is dropped | `bytes` (the seal's ciphertext, 8 × `blocks`) | game code sealing faster than it reveals or discards, or dropping a `Seal` without calling either |

Nothing sealed flows upstream, so there is no other server fact.

The options `sealed.maxOutstanding` (integer, unrevealed seals per player per definition, 1–256, default 1, chosen)
and `sealed.hideLength` (boolean, default true) are rows of `v5.md` §3.4's option table, the one home for definition
options, with their costs: the client holds up to `maxOutstanding` × 8 × ⌈W/8⌉ B per sealed definition and the server
one recipient set per outstanding seal; with `hideLength` every seal is ⌈W/8⌉ blocks, up to W − B + 7 B more per
seal, and the padded size is decrypted at the reveal.

**Decision: `hideLength` defaults to true.** Problem: the ciphertext's length is plaintext information disclosed
before the reveal (a layout's size, an answer's length), and sealing exists to disclose nothing before it. Options:
false (research's choice; padding to 8 B, length visible to 8 B) or true (padding to the worst case). Choice: true,
since security comes first and its cost is bytes and decrypt time this table states. For a codec of fixed size the
two are equal; a developer sets false where the length carries nothing.

**Cost** (`refusals-rejudged/r34_seal.out`, 3 runs per mode, at 1, 16 and 64 KB): 210.2–230.9 ns/B interpreted,
22.3–27.9 ns/B native, the same to seal and to open. A 16 KB seal: 3.4–3.8 ms on the client at the reveal,
0.37–0.46 ms on the server once per seal whatever the recipient count. A seal key: one HalfSipHash over 12 B on the
server at the reveal, 0.18–0.22 µs native for 8 B (12 B unmeasured).

### 9.8 What stays out

- **Commit–reveal for provably fair outcomes** (gacha, shuffles: H(seed) before the player acts, the seed after)
  guards against the server, not a client, and needs nothing from Lync: a docs recipe over two server-sent
  definitions and `EncodingService:ComputeStringHash(…, Enum.HashAlgorithm.Sha256)`, callable on both sides
  (security None, verified in the API dump) `[refusals-rejudged-1 R34 (b)]`.
- **Cryptographic state sharing between peers** stays refused: Roblox clients hold no state another peer must be
  denied; the server holds all state and chooses what each viewer receives (`interest`) `[refusals-rejudged-1 R34
  (c)]`.

## 10. Codes, counters and options added here

Each code gets its registry page (`v5.md` §7.1); the runtime and core-api units list them in `v5.md` §7.
- **Facts:** `withinExceeded`, `monotonicOutOfOrder`, `maxTotalExceeded`, `deriveMismatch`, `maxRateExceeded`
  (§1.5); `sealsOutstandingExceeded` (§9.7).
- **Declaration:** `roleMarkerMisplaced` (§7.1, `v5.md` §3.3), `sealedInstanceUnsupported` (§9.2); `sealed` where the
  definition doesn't take it is `v5.md` §3.4's `definitionOptionMisplaced`.
- **Caller:**
  - `fieldCodecUnsupported`: a check or telemetry call on a field handle whose codec that call doesn't take
    (`v5.md` §3.4 uses it for every declaration made through a handle);
  - `checkPoolMismatch`: two `maxTotal` checks in one pool with different `total`, `windowSeconds` or field unit
    (§4.2);
  - `declarationMisplaced`: a check or telemetry call on a definition outside its scope (§1.2, §8.1);
  - `telemetryDuplicate`: a second `aim` or `series` (on the definition or any of its fields), or a second `atom`,
    on one definition;
  - `atomSeriesMissing`: an atom's `series` names a definition with neither an `aim` nor a `series`;
  - `sealSettleDuplicate`: `reveal()` or `discard()` on a seal already revealed or discarded;
  - `claimUnverified`: `connect` or `handle` on a definition with an unverified claim leaf (§7.3, `v5.md` §3.3);
  - `callOptionUnknown`, `callOptionMissing`, `callOptionOutOfRange`, `callOptionWrongType`: `v5.md` §7.1's set for
    every run-time options table, used by every call here;
  - `fieldPathUnknown` (`v5.md` §3.4) for a `fields` key naming no field;
  - `perceptionMisplaced` (`v5-collections.md` §12.5) for `Lync.perception` outside a synchronous call (§1.7).
- **Faults:** `checkFunctionRaised`, `checkFunctionYielded` (§1.7, `v5.md` §6.1).
- **Build:** `freeFormRoleMissing` (`v5-tooling.md` §3.4).
- **Counters** (`v5.md` §7.4), per definition: `checksSkipped` (a `reference` or `fn` returned nil),
  `checksUndrawn` (a message `messagesPerCheck` didn't draw, §5.2), `checksExempted` (a message inside a
  `resetChecks` window, §1.6), `atomsDelivered`, `atomsSkipped` (§8.5), `checkFunctionsRaised`, `checkFunctionsYielded`
  (a check function's throw or yield, §1.7).
- **Build option:** `check.minFreeFormCodes` (§7.4; `v5-tooling.md` §2).
- **Configuration** (`Lync.configure`, `v5.md` §7.5): `telemetry.atomsPerBatch`, `telemetry.maxBatchSeconds`
  (§8.10).
- **Runtime constant:** `maxTotal` buckets, 16 (§4.1).
- **Schema hash** (`v5.md` §4.7): codec type 26 `role` (§7.1); the `sealed` option (§9.3).

## 11. Pending measurements and proofs

Each has a default or a rule the design uses; none blocks the milestone.
- Roblox's server build for checks and telemetry, and whether a Roblox server runs Lync's modules native; state
  lookup by `Player` against the probes' slot index.
- `Random:NextInteger` on Roblox servers (`messagesPerCheck`, §5.2); the seed entropy of an unseeded `Random.new()`
  and of `HttpService:GenerateGUID`, and whether either is cryptographic (h of §9.1, S of §9.4).
- The runner thread's cost native and in Roblox's build (§1.7).
- The engine's downstream rate per player (sealing against withholding, §9.1); HalfSipHash over 12 B (§9.7).
- The engine's replication delay for client-owned physics (`within` cause 1); jitter on mobile networks (the c of
  the docs' `tolerance` derivation, §6.2); reliable-lane stall lengths on mobile (`maxTotal` cause 2 and its 10%
  headroom, `limit.slackSeconds` behind the reliable c; review m11).
- Whether `GetServerTimeNow()` can decrease on a client, and whether the device clock can be set back
  (`monotonic` cause 4).
- Cross-device float results on arm64 clients, and FP contraction in Roblox's arm64 interpreter (`derive` cause 1).
- `Workspace:Raycast` cost inside a `fn` (`messagesPerCheck`'s use).
- Telemetry: the value-series cost, the record-form aim cost and the widened layout (§8.10); real frame-delta
  noise at a 60 FPS cap; the server-load timing burst (cause 10); the HTTP request body limit (§8.8); the three
  terms sources of §8.11.
- Typing proofs (`v5.md` §10): the runtime path's per-codec handle methods (each handle's methods picked by codec
  kind, `v5.md` §3.4), and the per-codec handle interfaces in TypeScript (`v5.md` §3.6), on which §1.2's and §8.6's
  types rest.
