# Lync v5: checks, claims, telemetry and sealed delivery

Draft 3.6, 2026-10-15. Part of the v5 design (`v5.md`); changes from draft 3.5 are in `v5-3.6-changes-checks.md`.
This file specifies, completely:
- **checks** (§1–§6): `within`, `monotonic`, `maxTotal`, `derive` and `maxRate`, declared on the server view;
- **claims** (§7): the `:claim()` and `:input()` codec markers, the claim requirement and the `freeFormField` lint;
- **telemetry** (§8): `aim`, `series`, `atom`, delivery to game code, and what Lync's docs must say about
  Roblox's terms;
- **sealed delivery** (§9): server-sent values sent before they become visible and revealed by a key.

They were the `checks` and `telemetry` extensions of `v5-extensions.md` and R34's form (a); they are now part of
the core. The markers and their hash (§7.1) are built in milestone 1, the claim requirement with validators in
milestone 2, the lint in milestone 3, and the rest in milestone 7 (`v5.md` §10). Codes, counters and options this
file adds are listed in §10; pending measurements in §11.

Every part follows `v5.md` §0: Lync reports facts with exact triggers and numeric evidence, and never rewrites a
value a client sent. A message is dropped only for a rule the developer declared: a `validate` returning `false` or
a check with `policy = "drop"`, as `limit` and traps already do (`v5.md` §6.1). Every bound is the developer's
option; Lync derives none from a model of the network. Nothing here scores, ranks, delays or throttles a player.
Code, counter and option names are provisional until the naming pass.

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

`Net.<definition>:field(path):<check>(options)`, with `<check>` one of `within`, `monotonic`, `maxTotal`, `derive`,
`maxRate` (`Net.strike:field("origin"):within({ … })`).
- **`field(path)`** is `v5.md` §3.4's field handle: `path` names a field of `data` through records and optionals
  (`""` is `data` itself when it isn't a record); arrays, maps and union variants are not reachable; an unknown path
  throws `unknownField`. A check on a field whose codec it doesn't take throws `fieldKind`. Checks take leaf codecs
  only, so a check is always on the leaf it verifies (§7.2).
- **Types.** `field(path)` selects by the literal and returns `Field<D, T>`; each check is one non-overloaded method
  of it, so options such as `derive`'s `fn` are typed by the field (`v5.md` §3.4, verified on both solvers and
  tsc).
- **Scope.** `data` of client-sent events and of client requests' asks. Replies to server `invoke`s are not
  covered: answers have no validator step, and the code that called `invoke` checks its result. A check declared on
  a field of a server-sent definition or a collection throws `viewPlacement`.
- **An absent optional.** A check whose field passes through an optional that is absent in a message is not
  evaluated for that message and changes no state.
- **When.** A check may be declared at any time; it applies to messages decoded after the call. There is no call
  that removes one. Its **index** is its 1-based position among the definition's checks in declaration order.
- **R35's modifiers** `[refusals-rejudged-4 R35]`: `maxRate` is kind 5 (§6), with `planar` as its `plane` option
  and as a `within` reference (§6.3); `exempt` is `resetChecks`' `seconds` (§1.6); `cooldown` stays `limit` (§6.5).

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
  - **What replaces `"clamp"`:** game code. The check runs with `"deliver"` (the `constraint` fact records the
    failure), and the handler limits the value with the formulas `clamp` used, given in the docs per codec: scalars
    r + clamp(v − r, −m, m); `t.angle` r ± m wrapped into [0, 2π); vectors r + (v − r) · m/|v − r|; for `maxTotal`,
    max(0, cap − S), which game code tracks itself. Lync offers no call for it, because a second way to rewrite would
    be the rejected option again.
  - Every failing check is reported as `constraint` (§1.5), whatever the policy.

### 1.4 Where checks run

`v5.md` §6.1's steps 5–7 run as follows:
- **Step 5** is unchanged: control; traps and reachability; answers; `unresolved`; `limit`; the report-only checks
  of milestone 5. Messages over `limit` therefore never touch check state.
- **Step 6, checks and validator**, per message of a definition, in this order (the claim requirement is enforced
  earlier, when the handler is declared, §7.3):
  1. **Evaluate** every check of the definition in declaration order. Each check reads its field once, at its own
     evaluation, and later steps use the value it read. Each failure records one `constraint` occurrence. A game
     function a check calls (`within`'s `reference`, `derive`'s `fn`) runs in its own thread (§1.7) and receives
     the same `data` table the validator and the handler receive; a change it makes to `data` is seen by later
     checks, the validator and the handler, never by a check that has already read its field.
  2. If any failing check has `"drop"`, the message is dropped (an ask is answered `rejected`); the validator is not
     called and nothing is committed.
  3. **Validate**, as today: `false`, a throw or a yield drops the message.
  4. **Commit**, for every message that passes step 6, whether or not a handler then receives it
     (`messagesUnheard`, `v5.md` §3.5): `monotonic` and `maxRate` store, `maxTotal` charges, each the value it
     read at step 1. A failing check with `"deliver"` commits too, so check state is a function of the messages
     that passed step 6.
  Messages of one frame are handled in order, each committing before the next is evaluated.
- **Step 6b, sample** (§8.3), then **step 7, delivery**.

Checks run before the validator, so a validator sees only messages that passed every `"drop"` check. Report-only
checks of milestone 5 stay in step 5, so they see messages a check or a validator later drops, as they already see
messages a validator drops.

### 1.5 The fact `constraint`

One reason with `kind` 1–5: `v5.md` §7.3's rule is one reason, or one evidence value, per trigger whose cause or
knob differs (draft 3.5 root cause C), and `kind` is that value, with known causes listed per kind in §2–§6. One
reason keeps evidence narrowing on `reason` alone, the form proven on both solvers `[probes review-2 t3]`, as
`unresolved`'s `what` does.

| Reason | Exact trigger | Action | Evidence | Known causes on an unmodified client |
|---|---|---|---|---|
| `constraint` | a check declared on the message's definition fails, by its kind's trigger: §2.2 (`kind` 1), §3.2 (2), §4.2 (3), §5.2 (4), §6.2 (5) | `"drop"`: dropped, ask `rejected`; `"deliver"`: delivered | `check` (the 1-based index, §1.2), `kind` (1 `within`, 2 `monotonic`, 3 `maxTotal`, 4 `derive`, 5 `maxRate`), `policy` (1 drop, 2 deliver), `observed`, `bound`, `span`, `against` (per kind, below), `late` (1 when the message's frame key is older than the stored key: only kinds 2 and 5 store a key, and only unreliable frames can be late (§3.1), so it is 0 for kinds 1, 3 and 4 and for reliable definitions), and on a window's closing fact `peakObserved`, `peakBound` (below) | per kind: §2.4, §3.4, §4.4, §5.3, §6.4 |

| `kind` | `observed` | `bound` | `span` (s) | `against` |
|---|---|---|---|---|
| 1 `within` | the distance d, in the field's unit | the maximum distance applied to this message | 0 | 0 |
| 2 `monotonic` | the value | the stored value | 0 | 0 |
| 3 `maxTotal` | the window sum S plus the amount | `cap` | 0 | 0 |
| 4 `derive` | the distance d after snapping (1 for an unequal `t.enum` or `t.bool`) | `tolerance` | 0 | 0 |
| 5 `maxRate` | d against the failing reference | that reference's allowance, `rate` × `span` + `burst` | t − t_p or t − t_a | 1 previous value, 2 anchor (1 when both fail) |

The zeros are fixed values of fields a kind has no use for; narrowing on `kind` is not proven on the old solver, so
the evidence set stays flat (`span` and `against` are R35's).

- Evidence is numbers from the decoded value and the server's own value, never client bytes.
- **Decision: one window per check** (review M2). Problem: `v5.md` §7.3 keys a window by (player, reason,
  namespace, definition), so two checks of one definition coalesce and the closing fact carries only the last
  occurrence's evidence; the tuning workflow (run `"deliver"`, read `observed`, set the bound, §2.4, §5.3) needs
  each check's own numbers, and the largest of them. Options: (a) the core key, last occurrence only; (b) **the
  key gains `check`, and the closing fact also carries the window's peak**. Choice: (b). `constraint`'s key is
  (player, reason, namespace, definition, `check`), and a closing fact carries `peakObserved` and `peakBound`, the
  `observed` and `bound` of the window's occurrence with the largest |`observed` − `bound`| (the first such on a
  tie; on a fact delivered at a window's first occurrence they equal `observed` and `bound`). Both are a maximum of
  reported numbers, exact, not a statistic about a player. The caps (`observe.perPlayerEvents`) count each key as
  core keys do.
- Recording costs 20.5 ns native per occurrence `[diagnostics §9]`.

### 1.6 State and `resetChecks`

- **State** is kept per (player, check), or per (player, pool) for a `maxTotal` pool. It is allocated at the
  player's first message that reaches the check and freed when the player leaves.
- **`Net.<definition>:resetChecks(player, options?)`**, `options = { seconds, check }`, clears that player's state
  for the scoped checks, including the windows of the pools their `maxTotal` checks belong to. The scope is the
  check at index `check`, whatever its kind; with `check` nil, every check of the definition that keeps state
  (`monotonic`, `maxTotal`, `maxRate`), since only state needs reseeding: `within` and `derive` keep running (review
  M1). For `seconds` after the call, the scoped checks don't evaluate that player's messages of the definition and
  commit nothing; each such message is counted once in `checksExempted`. After the window, the next message seeds
  the state. It is the call for rounds, respawns and teleports.
- **Why a duration** `[refusals-rejudged-4 R35]`: messages the client sent before a server-applied move are still in
  flight after the call, and with an instant reset the first of them reseeds `maxRate` or `monotonic` with the old
  value, so the first message after the move fails: one fact per teleport, with `observed` about the teleport's
  distance. No frame key separates them, since those frames are newer than any the server has seen. The docs'
  formula for `seconds` after a server-applied move on `v5.md` §9's model: the client keeps sending old values until
  the move reaches it, and they arrive a one-way trip later: 2 × (0.05 + 0.02) s, plus a server flush, a client
  frame and a server step of 1/60 s each, 0.19 s; on the reliable lane add the 2 s stall slack. The game knows its
  own ping (`GetNetworkPing`).

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `seconds` | number (real) | s | 0–10 | 0 (chosen: an instant reset) | one time comparison per message of the definition while a window is open |
| `check` | integer or nil | 1-based check index | 1 to the definition's check count | nil: every check of the definition | none |

### 1.7 Game functions inside checks

- **Problem** (collections review B2, checked). Luau lets a coroutine yield across `xpcall`, so a game function that
  yields under `xpcall` (`task.wait`, `WaitForChild`, a DataStore call) suspends the thread running the inbound
  pipeline: that frame's remaining messages, and the flush, wait until the engine resumes it, and a re-entrancy flag
  sees the yield only at the next entry (`v5-collections.md` §8.5's case; checked again here with luau 0.740: a
  "flush" coroutine calling a yielding function under `xpcall` returned `suspended` and never reached its end).
- **Rule: every game function a check calls runs in a thread of its own.** Lync resumes a runner thread with the
  function and its arguments; the runner calls it and yields a completion marker with the results. After
  `coroutine.resume` returns, exactly one of three holds:
  - **returned:** the resume returned true with the marker; the results are the function's. A result outside the
    check's domain is raised inside the runner before the marker, so it is a throw: the wrong type, a non-finite
    number or component, or, for `derive` on `t.direction`, a zero vector (§5.1);
  - **threw:** the resume returned false. Reported natively as `validatorError` with `debug.traceback(thread,
    message)`; the runner is dead and a new one is made for the next call;
  - **yielded:** the resume returned true without the marker (`coroutine.status` is `"suspended"`). Reported
    natively as `validatorYielded`; Lync calls `task.cancel(thread)`, which closes the thread so neither game code
    nor the engine's scheduler resumes it (documented, creator-docs `libraries/task.yaml`), and makes a new runner.
    Whatever the function did before its yield stays done.
  In the last two cases the message is dropped (an ask is answered `rejected`), checks after it are not evaluated,
  occurrences already recorded stand, and the definition's `validatorErrors` counter rises by one, as for a
  validator (`v5.md` §7.4). Native reports are spaced per (code, definition) per `observe.window`, and name the
  function (`arena.strike:field("origin"):within reference`). The pipeline thread never runs game code, so a
  yield costs nothing to the frame or the flush.
- The same rule fits the validator; `v5.md` §6.1 is the runtime unit's (this file's change record, Needs elsewhere).
- A function returning nil skips its check for that message, counted in `checksSkipped`; nothing is committed for
  that check.
- **Cost** (checked, luau 0.740 CLI, interpreted, best of 5 × 2 × 10^6 calls of a two-argument function): a direct
  call 22.5 ns, under `xpcall` 28.3 ns, through a reused runner thread 101.5 ns, through a new thread per call
  245.3 ns. So the runner adds about 73 ns per game function against `xpcall`, plus one thread creation after each
  throw or yield; native and Roblox's build are unmeasured (§11).
- **`Lync.perceived(player)`** may be called inside a `reference` or `fn`, as in the validator and the handler
  before its first yield, for the message's own player; it returns the perceived ticks of the message's frame, the
  same value in each call. Anywhere else it throws `perceivedOutsideDispatch` (`v5-collections.md` §12.5). So a
  `within` reference can read rewound state: `Net.fighters:rewound(Lync.perceived(player), key)`.

## 2. `within`

### 2.1 Semantics

`Net.strike:field("origin"):within({ reference = rootOf, maxDistance = 6, policy = "drop" })` `[checks-telemetry C1]`.
- Per message Lync calls `reference(player, data)`, which returns `(r, m?)`: the server's value to compare against,
  and optionally a maximum distance for this message alone (speed × elapsed time, say), which replaces
  `maxDistance` for it. r nil skips the check (§1.7).
- **Distance d**, by the field's codec:
  - `t.int`, `t.number`, `t.f32`, `t.f64`: |v − r|;
  - `t.angle`: min(δ, 2π − δ) with δ = |v − r| mod 2π;
  - `t.vector3`, `t.vector3f32`: |v − r|;
  - `t.direction`: acos(clamp(v · r̂, −1, 1)), with r̂ = r/|r| (r = 0 gives NaN).
- Other codecs (`t.cframe`, `t.rotation`, records, arrays, enums, strings, the rest) throw `fieldKind`. A `t.cframe`'s
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
   reliable-lane stall (the simulated p99, `v5.md` §4.9). For physics the client owns, the engine's replication
   delay adds an unmeasured amount (§11). A reference that reads `rewind` at the client's perceived tick
   (`Net.c:rewound(Lync.perceived(player), key)`, `v5-collections.md` §12.5) removes the latency term for records
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
| `reference` | `(Player, Data) -> (R?, number?)`; R is `number` for scalars and `t.angle`, `Vector3` for vectors and `t.direction` | — | — | required | the game's own, once per message, in its own `xpcall` (§1.7) |
| `maxDistance` | number (real) | the field's unit: studs, radians for `t.angle` and `t.direction`, the integer's unit | ≥ 0, finite | required | none |
| `policy` | `"drop" \| "deliver"` | — | — | required | none |

Measured, net of the runner's per-message baseline `[checks-telemetry C6]`: 50–56 ns native and 101–109 ns
interpreted per message for a vector field, 47–49 and 108–116 ns for a number field; a failure adds 20.5 ns native.
State 0 B; wire 0 B.

## 3. `monotonic`

### 3.1 Semantics

`Net.input:field("seq"):monotonic({ order = "increasing", policy = "drop" })` `[checks-telemetry C2]`: a number that
unmodified client code never decreases in send order (`"nondecreasing"`) or always raises (`"increasing"`).
- **Frame key.** On the reliable lane, the number of reliable frames the server has accepted from the player on
  this connection before this one, counting from 0 (the wire unit defines the count, `v5.md` §4.5); on the
  unreliable lane, the frame's extended upstream seq (`v5.md` §4.4). Messages of one definition in one frame are in
  call order (`v5.md` §4.1), so they share a key and are compared in order.
- **Why not the tag count** (review B1, checked by the reviewer's probe): `REKEY` restarts the tag count at 0
  (`v5.md` §4.5), so after one `desync`, a known cause on an unmodified client, every reliable frame would be
  "late" until the new count passed the old one: 999 of 1000 rising values failed `"nondecreasing"`, and 999 of
  999 stale values passed, which a client can force with 8 bad tags. The accepted count is never reset, and
  reliable frames arrive in order, so no reliable frame is late.
- **State:** the stored key s* and value v*, two f64 per (player, check).
- Codecs: `t.int(min, max)`, `t.int()`, `t.number`, `t.f32`, `t.f64`. `t.angle` wraps, so it is `fieldKind`, as is
  every other codec.

### 3.2 Exact trigger

For a value v in a frame with key s:
- no stored value: never fails;
- s ≥ s*: fails when v < v* (`"nondecreasing"`) or v ≤ v* (`"increasing"`); `late` = 0;
- s < s* (a late frame, possible only on the unreliable lane, §3.1): fails when v > v* (`"nondecreasing"`) or v ≥ v*
  (`"increasing"`), since a value sent earlier can't exceed one sent later; `late` = 1.

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

`Net.collect:field("coins"):maxTotal({ cap = 5000, seconds = 600, policy = "drop" })` `[checks-telemetry C3]` bounds the
running sum of a field per player over a window timed by server arrival on `os.clock()`, never by client time (R20,
R21).

**Decision: the window mechanism** (`checks-telemetry/maxtotal_bounds.out`, cap 1000, 60 s, a message every 0.05 s
for 600 s):

| Mechanism | Largest accepted sum, greedy sender | State per player | Cost, native (net) |
|---|---|---|---|
| (a) **sliding window of 16 buckets** | any 56.25 s: 1.00 × cap; any 60 s: 2.00 × cap; long run: cap/seconds | 144 B | 74–84 ns |
| (b) token bucket (capacity cap, refill cap/seconds) | any 56.25 s: 1.94 × cap; any 60 s: 2.00 × cap | 16 B | 65–66 ns |
| (c) exact window, a ring of every committed (time, amount) | any 60 s: cap (derived) | 16 B per message in the window, 48 KB per player per check at 5 messages/s over 600 s (derived), and a `limit` to bound it | not measured |

- **Choice: (a).** A rule written per window ("5000 coins per 10 minutes") means a sum over the window; (a) bounds
  any span of up to 15/16 × `seconds` to `cap` exactly, in constant memory and without requiring a `limit`. (b) lets
  a sender take 1.94 × `cap` within 15/16 of the window. (c) is exact for 330× (a)'s memory at the example rate.
- **The bucket count, 16,** is a runtime constant (chosen: it sets the guarantee at 15/16 of the window for 144 B;
  32 buckets would give 31/32 for 272 B. A game rule that needs the full window would change it).

### 4.2 Exact trigger

Let w = `seconds`/16, k = ⌊`os.clock()`/w⌋ at evaluation, and S the sum of amounts committed for (player, check or
pool) in buckets k − 15 … k. The check fails when S + v > `cap`. **Commit** (§1.4) adds v to bucket k.
- **Exact arithmetic** (review m1, checked by the reviewer: in f64, 0.1 + 0.1 + 0.1 > 0.3, so a third 0.1 would
  fail a 0.3 cap). Amounts are summed as integers: for `t.int`, the value; for `t.number(min, max, step)`, the value
  in units of `step`, (v − min)/step + min/step, which is an integer because the decoder gives min + q · step and
  `min` must be a multiple of `step` (within `v5.md` §3.3's 1e-9 rule; otherwise `fieldKind`). `cap` is converted
  once, at declaration, to ⌊cap/step⌋ units by the same 1e-9 rule. S is recomputed from the 16 bucket sums at each
  evaluation, never kept by adding and subtracting, and every sum is an integer below 2^53 (`cap` ≤ 2^53 units).

**Guarantee** (derived, and measured above): any span of 15/16 × `seconds` or less holds at most `cap` of committed
amounts while every failing message is dropped; any span of `seconds`, at most 2 × `cap`; the long-run rate is at
most `cap`/`seconds`. Under `"deliver"`, failing amounts are committed too (§1.4), so S is the sum game code
received and `observed` reports how far it went past `cap`.

- **Codecs:** `t.int(min, max)` and `t.number(min, max, step)` with min ≥ 0. `t.int()`, `t.f32`, `t.f64` and any
  codec with negative values are `fieldKind`: a negative amount would refund the window.
- **`pool`:** checks with the same pool name, on any definitions of the namespace, share one window per player
  (coins from `collect`, `sell` and `quest`). They must declare equal `cap` and `seconds`, and fields of equal unit
  (equal `step` for `t.number`), else `checkPool`. A pool whose checks mix `"drop"` and `"deliver"` commits the
  `"deliver"` checks' failing amounts too, so the guarantee above holds only for pools whose every check drops.

### 4.3 What it protects, and how it is defeated

- **Protects** the rate of gain of client-claimed amounts (currency, experience, items or damage in a claim field):
  Roblox's documented "Rate of Gain" heuristic `[anticheat-design §4.2]`. A forged stream is bounded to `cap` per
  15/16 window and `cap`/`seconds` in the long run.
- **Defeated by** claiming exactly the allowance every time, and by spreading amounts over definitions that aren't
  in one pool. It is no substitute for computing the gain on the server, which needs no check.

### 4.4 Known causes on an unmodified client

`checks-telemetry/maxtotal_bounds.out`:
1. **A cap below what play produces** within 15/16 × `seconds`: a bonus event, a purchase that doubles rates.
2. **A stream at exactly cap/seconds** fails at bucket edges: 10 of 12,000 amounts with no stall, 84 with one 5 s
   reliable stall.

Not causes: stalls with headroom (at 90% of cap/seconds, no failure with one stall of 0, 0.85, 2 or 5 s); lost
messages (never charged); messages `validate` refuses (never committed). The docs recommend 10% headroom, from this
measurement.

### 4.5 Options and cost

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `cap` | number (real) | the field's unit, per window | > 0, ≤ 2^53 | required | none |
| `seconds` | number (real) | s | 1–3600 | required | bucket width `seconds`/16 |
| `pool` | string or nil | — | 1–64 B | nil: the check's own window | one window per player per pool instead of per check |
| `policy` | `"drop" \| "deliver"` | — | — | required | none |

Measured, net: 74–84 ns native and 240–248 ns interpreted per message, including clearing up to 16 sums when a
message enters a new bucket `[checks-telemetry C6]`. State 144 B per player per check or pool; wire 0 B.

## 5. `derive`

### 5.1 Semantics

`Net.shot:field("landing"):derive({ fn = landingOf, tolerance = 0.25, policy = "deliver" })` `[server-facts §U9.2]`: the
server re-computes an outcome the client sent from the inputs in the same message and compares.

```luau
-- server
local Projectile = require(ReplicatedStorage.Shared.Projectile) -- the module the client also calls
Net.shot:field("landing"):derive({
	fn = function(player, shot) return Projectile.landing(shot.origin, shot.velocity, shot.flight) end,
	tolerance = 0.25, -- studs
	policy = "deliver",
})
Net.craft:field("result"):derive({
	fn = function(player, craft) return Recipes.result(craft.recipe, craft.inputs) end,
	tolerance = 0, -- t.enum: exact
	policy = "drop",
})
```

- **Decision: shape.** Options were the research's `:claim(Lync.derive(fn, tolerance))` in the shared schema
  (refused by M8: functions can't live in the shared schema), a docs recipe over `within` (it compares an unsnapped
  value, can't take `t.enum` or `t.bool`, and reports `kind` 1, whose causes are latency), and **a fourth check
  kind**. Choice: the fourth kind, which reuses §1 whole and adds snapping, exact codecs and its own `kind`
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
     at declaration, to an integer K by `v5.md` §3.3's 1e-9 rule: ⌊tolerance/step⌋ for `t.number` (1 for `t.int`),
     ⌊(tolerance/step)²⌋ for `t.vector3`, ⌊tolerance · n/2π⌋ for `t.angle`. The comparison is integer: k against K.
     `observed` reports √k · step, k · step or k · 2π/n in the field's unit. `t.direction`, `t.f32`, `t.f64` keep
     §2.1's float metric; `t.enum` (both forms) and `t.bool` give 0 or 1.
- **Codecs:** §2.1's list, plus `t.enum` and `t.bool`. Records, arrays, maps, unions, `t.cframe` and `t.rotation`
  are `fieldKind`; a record outcome is one `derive` per leaf.
- `derive` keeps no state; commit stores nothing.

### 5.2 Exact trigger

The check is evaluated for a message when `oneIn` is 1, or when a draw `Random:NextInteger(1, oneIn)` returns 1 from
a `Random.new()` instance created without a seed at server start and used for nothing else (an unseeded `Random`
"uses a seed from an internal entropy source", documented, creator-docs `datatypes/Random.yaml`). The draw happens
after the frame arrived, so a client can't know before sending which of its messages are evaluated. An evaluated
check fails when not (k ≤ K) on a grid codec, or not (d ≤ `tolerance`) on the others (§5.1 step 3); equality
passes. A message not drawn is not evaluated, passes, and is counted in `checksUndrawn` (review M1), so every way a
claim passes unchecked has a count.

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
   `Net.<def>:round(data)` (`v5.md` §3.5).
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
| `fn` | `(Player, Data) -> T?`, T the field's decoded type | — | — | required | the game's own, per evaluated message, in its own `xpcall` (§1.7) |
| `tolerance` | number (real) | the field's unit | 0–2^31, finite; only 0 for `t.enum` and `t.bool` | required | none |
| `policy` | `"drop" \| "deliver"` | — | — | required | none |
| `oneIn` | integer | messages per evaluation | 1–1000 | 1 (derived: principle 1, every message is checked unless the developer trades that for `fn`'s cost) | above 1: one draw per message, 24–32 ns in the CLI (`v5-integrity.md` §4's figure; `Random:NextInteger` on Roblox servers unmeasured, §11) and `fn` on 1/`oneIn` of messages on average; a message not drawn passes unchecked, under `"drop"` too |

- **Types.** `Net.shot:field("landing")` is a `Field<ShotData, Vector3>`, whose `derive` takes `{ fn: (Player,
  ShotData) -> Vector3?, tolerance: number, policy: "drop" | "deliver", oneIn: number? }`, so `fn`'s return type is
  the field's (`v5.md` §3.4's field handles; roblox-ts the same, `this: void`).
- **Measured** (`server-facts/server_facts_cost.out`): Lync's share for a vector field is 6–12 ns native and
  32–36 ns interpreted per message; with an exact compare (`t.enum`) the whole runner is 7.2–8.5 ns native. Add the
  protected call (§1.7) and 20.5 ns per failure. State 0 B; wire 0 B.

## 6. `maxRate`

### 6.1 Semantics

`Net.move:field("position"):maxRate({ rate = 16, burst = 0.907, window = 10, plane = "xz", policy = "deliver" })`
`[refusals-rejudged-4 R35]`: a claimed value that changes no faster than `rate` per second, in the field's unit.
- **Why a kind, not a recipe.** A `within` whose reference returns the game's last delivered value plus `rate` ×
  elapsed fails twice: game code never sees frame keys, so late unreliable frames (1.3%, §3.2) move its last value
  backwards; and a per-step bucket accumulates quantization error. The research's leaky bucket on |Δ| reached
  149 studs (unreliable) and 309 studs (reliable) over 3 × 10^6 messages of a client moving at exactly 16 studs/s,
  `t.vector3` step 1/32 (`refusals-rejudged/r4_maxrate.out`), and it grows with session length. So the form compares
  samples pairwise against two references.
- **State** per (player, check), 80 B: the newest committed value p with its evaluation time t_p and frame key, and
  an anchor a with its time t_a.
- **Distance d(x, y):** §2.1's metric (`t.int`, `t.number`, `t.f32`, `t.f64`, `t.angle`, `t.direction`, `t.vector3`,
  `t.vector3f32`); for the two vector codecs with `plane = "xz"`, |x − y| over X and Z only. Other codecs are
  `fieldKind`.

### 6.2 Exact trigger

For a value v in a frame with key s, evaluated at t (`os.clock()` at evaluation): with no stored value, never.
Otherwise it fails when not (d(v, p) ≤ `rate` × (t − t_p) + `burst`), or not (d(v, a) ≤ `rate` × (t − t_a) +
`burst`); equality passes. A late frame (s older than the stored key, unreliable only: §3.1's key) is compared with
both references, `late` = 1.

**Commit** (§1.4): if s is newer than the stored key, (p, t_p, key) ← (v, t, s), and when t − t_a ≥ `window` also
(a, t_a) ← (v, t). The first message sets both. A late frame stores nothing.

**Why two references.** The previous value bounds a jump against the last sample, so a jump can't spend allowance
accrued before that sample; the anchor bounds net displacement over up to `window`, which catches sustained excess
speed that per-step comparisons let through. Each is one comparison of two samples, so honest error doesn't
accumulate.

**Decision: `burst` and `window` are required.**
- **Problem.** `burst` must cover an honest pair's excess, which has two parts: each sample's decode error e, which
  the codec fixes exactly, and the compression of arrival spans against send spans, which depends on the player's
  real network, unknown to Lync. `window` sets how long sustained excess speed may run before the anchor sees it.
- **Options:** (a) R35's defaults, `burst` derived from `v5.md` §9's simulated network and `window` 10 s, chosen
  `[refusals-rejudged-4 R35]`; (b) **both required**, with the derivation in the docs.
- **Choice: (b).** A default from a network model is a threshold Lync would be guessing for every game, which the
  rule "Lync does only what it can do exactly" gives to the developer; `maxDistance`, `tolerance` and `cap` are
  required for the same reason.
- **The docs' derivation:** `burst` = `rate` × c + 2e. On `v5.md` §9's model, c = jitter range + client flush +
  server step = 0.02 + 1/60 + 1/60 = 0.0533 s on the unreliable lane, plus `limit`'s 2 s stall slack on the reliable
  lane (`v5.md` §4.9): 2.0533 s. e = √3 · step/2 for `t.vector3` (√2 · step/2 with `"xz"`), step/2 for `t.number`,
  π/n for `t.angle`, the octahedral error for `t.direction` (0.2369° at 10 bits), 0 for `t.int` and `t.f64`; `t.f32`
  and `t.vector3f32` err by 2^−24 of the value, so their e is 2^−24 × the largest magnitude the game sends (R35's e,
  2^−24 × the largest magnitude the codec admits, is about 2 × 10^31 for an unbounded `t.f32`). At 16 studs/s and
  `t.vector3` step 1/32 this gives 0.907 studs unreliable and 32.907 reliable.

Checked against the simulation (rate 16 studs/s, step 1/32, 3 × 10^6 messages per line,
`refusals-rejudged/r4_maxrate.out`); the model sends each sample in the frame it is taken, so its needs sit at least
`rate`/60 = 0.27 studs below the derivation, which covers a flush up to 1/60 s after the sample:

| Lane and network | Smallest `burst` with no failure | The docs' derivation |
|---|---|---|
| unreliable, jitter 0.02 s, 5% loss | 0.309 studs | 0.907 |
| unreliable, jitter 0.05 s (673,080 late frames) | 0.576 | 0.907 (derived at 0.02 s) |
| reliable, jitter 0.02 s | 0.309 | 32.907 |
| reliable, 0.85 s stalls at 1/600 per frame | 13.408 | 32.907 |

### 6.3 What it bounds, and how it is defeated

- A forged stream stays within `rate` × elapsed + `burst` of the previous sample and of the anchor; the excess speed
  it can sustain unseen is `burst`/`window`: 0.091 studs/s (0.57% of 16 studs/s) at `burst` 0.907 and `window`
  10 s.
- A client that withholds messages for T seconds may then move `rate` × T + `burst`: the server can't know where it
  was in between, so that is the bound.
- Defeated by moving at `rate` exactly, and by any client physics change `rate` allows. It bounds only what the
  client claims in Lync payloads, never engine-replicated characters; a game with server truth compares against it
  with `within`.
- **`planar` on `within`** needs no option: a reference returning `Vector3.new(r.X, v.Y, r.Z)`, v being the claim,
  makes `within`'s distance the XZ distance, exactly equal in f32 arithmetic in 10^6 of 10^6 random pairs
  (`refusals-rejudged/r4_cooldown.out`). The docs give the line. `maxRate` needs `plane` because its references are
  Lync's state, which game code can't reach.

### 6.4 Known causes on an unmodified client

1. **Game-applied motion:** teleports, respawns, seats, vehicles, knockback, conveyors. Call `resetChecks` with
   `seconds` (§1.6) where the game moves the player.
2. **Falling and jumping** with `plane = "xyz"`: a falling character's vertical speed grows under
   `Workspace.Gravity` (196.2 studs/s² by default), so it passes a walking `rate` about `rate`/196.2 s into a fall.
   Ground movement uses `"xz"`, as Roblox's movement-validation guidance says (documented, creator-docs
   `scripting/security/network-ownership.md`).
3. **A server step longer than 1/60 s** (a hitch), or a reliable stall longer than 2 s, compresses arrival spans by
   its length; evidence `span` shows it.
4. **Network jitter above the c the developer's `burst` covers** (mobile jitter unmeasured, §11), and a speed boost
   above `rate`.

### 6.5 Options and cost

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `rate` | number (real) | the field's unit per second | > 0, finite | required | none |
| `burst` | number (real) | the field's unit | ≥ 0, finite | required (§6.2; the docs' derivation) | none |
| `window` | number (real) | s | 0.1–3600 | required (§6.2) | none; unseen excess speed is `burst`/`window`, so a larger window lets less through |
| `plane` | `"xyz" \| "xz"` | — | `"xz"` only for `t.vector3` and `t.vector3f32` (else `callOptionRange`) | `"xyz"` (the codec's own metric, as in `within`) | none; `"xz"` is 3–11 ns cheaper native (`r4_maxrate.out`) |
| `policy` | `"drop" \| "deliver"` | — | — | required | none |

Measured, net (`refusals-rejudged/r4_maxrate.out`, 3 runs, best of 7): 84–85 ns native and 318–330 ns interpreted per
message in 3-D; 74–82 ns native and 299–305 ns interpreted with `"xz"`. State 80 B per player per check; wire 0 B.

**`cooldown`** stays out: a cooldown of s seconds is `limit = { perSecond = 1/s, burst = 1 }` (`v5.md` §5.4). The
client never sends two messages less than s apart; the server admits at most 1 + (T + 2)/s over any T seconds
(`refusals-rejudged/r4_cooldown.out`: after idle, 5 at once at s = 0.5 s, 3 at 1 s; for s > 2 s a second only s − 2 s
after the first). A stricter arrival-gap test would need the same 2 s stall slack, so a second limiter would add
nothing, and principle 4 refuses it.

## 7. Claims

### 7.1 The markers `:claim()` and `:input()`

Two codec methods in the shared schema, non-generic and returning the same codec type (`v5.md` §3.3's rule):
`t.int(1, 2 ^ 40):claim()`, `t.string(200):input()` `[checks-telemetry C4]`.
- **Roles.** A leaf is an *input* (the client's own control or choice) or a *claim* (what the client asserts about the
  world: a hit target, a shot origin, an amount gained, a completion time) `[anticheat-design §3.2]`. A leaf's role is
  the nearest marker on it or on a codec enclosing it within the payload; unmarked leaves are inputs. So
  `{ … }:claim()` marks a whole record, and an inner `:input()` overrides it for its own leaves.
- **Placement.** Markers are allowed only in client-sent payloads: `data` of `from = "client"` events and requests,
  and `reply` of `from = "server"` requests. Anywhere else (server-sent `data`, a client request's `reply`, collection
  fields) is the declaration error `rolePlacement` at the definition's line.
- **Decision: hashing.** (a) Not hashed, an exception to "every value in the schema goes into the schema hash"
  (`v5.md` §3.4); (b) **hashed as a wrapper codec**, type 26 `role`: role u8 (1 input, 2 claim), then the codec
  (`v5.md` §4.7). Choice: (b): no exception, 2 B of hash input per marker, nothing at run time. A changed role gives
  `MISMATCH` between builds, which never meet in production because both shards come from one build run.
- **Types:** unchanged; a marker doesn't change `T`.
- **`:input()`** has one effect: it silences `freeFormField` on a free-form leaf (§7.4). Draft 3.5 dropped it (M4:
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
  verified only by a validator. No declaration can be removed, so a leaf once verified stays verified.
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
  before a handler exists reach no handler and are counted in `messagesUnheard` (`v5.md` §3.5).
- **What it guarantees, exactly** (review M1): no message holding a claim leaf reaches `connect` or `handle` unless
  a validator ran on it, or each check declared on the leaf either was evaluated on it, or skipped it in one of
  three counted ways: its game function returned nil (`checksSkipped`), `oneIn` didn't draw it (`checksUndrawn`), or
  it fell in a `resetChecks` window (`checksExempted`). A developer who needs every claim evaluated gives the
  definition a validator, or a reference that never returns nil, `oneIn` 1 and no window on that check. It is
  defeated by a validator that returns `true` unconditionally, and by marking a claim `:input()` to silence the lint.

```luau
-- shared schema
strike = Lync.event({ from = "client", lane = "unreliable", data = {
	target = t.int(1, 2 ^ 40):claim(), origin = t.vector3(-2048, 2048, 1 / 32):claim(), aim = t.direction(11),
} }),
-- server: verifiers first, then the handler
Net.strike:field("origin"):within({ reference = rootOf, maxDistance = 6, policy = "drop" })
Net.strike:field("target"):refers(Net.fighters) -- v5-integrity.md §8
Net.strike:validate(function(player, s) return Fighters.alive(s.target) end)
Net.strike:connect(onStrike)
```

### 7.4 The `freeFormField` lint

The rule, its evidence, severity option and channel are the `freeFormField` row of `v5-tooling.md` §3.4: a free-form
leaf (unbounded floats and integers, more than 65,536 codes per component, strings, buffers, instances, custom
codecs) in a client-sent payload with no role marker on itself or an enclosing codec. Its relation to this file:
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
  `check.freeFormCodes` (integer, codes per component, 2–2^53, default 65,536, chosen: below it are every input of
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
- **Scope** as checks (§1.2): `data` of client-sent events and client requests' asks, on the server; elsewhere
  `viewPlacement`. A sampled field is named by its field handle (§1.2: `unknownField`, `fieldKind`); `atom`'s
  `fields` are path strings, typed as unions of the paths it accepts (`v5.md` §3.4). Declared at any time; applies
  to frames decoded after the call.

### 8.2 Streams and their entries

Each declaration keeps one ring per player of `ring` entries; one ring per definition, so a definition names its
ring (a second `aim` or `series`, on the definition or any of its fields, throws `telemetryTwice`).
- **Timing** (`Net.<def>:series(options?)`): one entry per frame carrying a delivered message of the definition.
- **Values** (`Net.<def>:field(path):series(options?)`): the same, plus the field's value. Scalars (`t.int`,
  `t.number`, `t.f32`, `t.f64`, `t.angle`, `t.bool` as 0 or 1, a list enum's 0-based index, a Roblox enum item's
  `Value`) are stored as the nearest f32, so integers above 2^24 lose precision; vectors (`t.vector3`, `t.vector3f32`,
  `t.direction`) as three f32. Lync stores values; differences are the analyst's.
- **Aim** (`Net.<def>:field(path):aim(options?)`): the field's look direction as yaw and pitch. Each aim codec gives
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
| 0–3 | `ms` u32 | ⌊`os.clock()` × 1000⌋ mod 2^32 when Lync received the frame (server arrival, never client time, R20) |
| 4–7 | `key` u32 | the frame key (§3.1) mod 2^32 |
| 8–11 | aim: `yaw` u16, `pitch` u16; scalar: f32 | aim and scalar series |
| 8–19 | three f32 | vector series |

Entry sizes: timing 8 B, aim 12 B, scalar 12 B, vector 20 B. The research's layout had u16 `ms` and `key`
`[checks-telemetry T1]`; with them, a ring of a definition sent less often than once per second spans more than the
65.536 s wrap, its times alias, and the window search (§8.4) is no longer sorted. u32 fields are exact while a ring spans less than
24.8 days (2^31 ms, the reach of the signed 32-bit differences of §8.4; `key` wraps after 414 days at 120
frames/s), for 4 B more per entry.

**Decision: one entry per frame.** A frame's messages share one arrival time, so Lync samples the last delivered
message of the definition in each frame (messages are in call order, `v5.md` §4.1): more entries would add values
with no time between them, and one per frame bounds a ring's turnover by its definition's lane budget (a definition uses one
lane: at the defaults 60 frames/s reliable or 120 unreliable, plus a burst of 240, `v5.md` §7.5). At 60 frames/s a 64-entry ring holds 1.07 s.

### 8.3 Where it runs

**Step 6b, sample** (§1.4), after the checks' commit and before delivery, on messages that will be delivered, with
the values game code receives. Dropped messages are not sampled: each drop is already a fact or a counter
(`overLimit`, `constraint`, `validatorRejections`), and sampling them would make a second record of one event. It runs
in the pipeline loop, not in a handler thread, so a yielding handler can't delay it. `ms` and `key` are read once per
frame.

### 8.4 Atoms

`Net.<def>:atom({ before, after, fields, series, pending })`: a fixed record taken when a message of the definition
is delivered, with a window of another definition's stream around it. One atom declaration per definition (a second
throws `telemetryTwice`).
1. **Trigger** (step 6b). When at least one `Lync.telemetry.atoms` connection exists and the player has a free pending
   slot, Lync copies the header and the `fields` values (as f64, a vector as x, y, z) into the slot, due at
   `os.clock()` + `after`. With no free slot it takes nothing and counts `atomsSkipped`; it never evicts. With no
   connection it takes nothing.
2. **Complete**, once per flush, where fact windows are swept (`v5.md` §7.3). For each due atom, Lync binary-searches
   the `series` ring for the first entry whose `ms` is no older than the trigger's `ms` − 1000 × `before` (u32
   differences, exact by §8.2), and copies it and every newer entry into the player's batch buffer.
3. **Hand off** (§8.5).

**Atom layout, version 1:** `serverTime` f64 (`GetServerTimeNow()` at the trigger frame), `ms` u32 and `key` u32 of
the trigger frame, `n` u16 (entries copied; at most `ring`, 1024), `flags` u8, the field values as f64 in declaration
order, then n entries. Size = 19 + 8 · F + n · E, with F the field values and E the entry size: 591 B for 4 values
(`origin` x, y, z and `target`) and 45 aim entries. **Flags** record what happened to the copy and the message, each
with an exact condition:
- bit 0: a check with `policy = "deliver"` failed on the trigger message (its `constraint` occurrence exists);
- bit 1: truncated: the ring's oldest entry is newer than the trigger's `ms` − 1000 × `before`;
- bit 2: partial: the player left before `after` elapsed, so the atom completed at the leave.

The research's clamp bit is gone with `clamp` (§1.3). An entry's time relative to the trigger is
(entry.`ms` − atom.`ms`) as a signed 32-bit difference, in ms.

### 8.5 Decision: how samples reach game code

| Option | Cost | Memory | Fit |
|---|---|---|---|
| (a) a callback per atom | a frozen table and a pooled-thread resume per atom: 259 ns native to build, 88–131 ns to resume `[diagnostics §5.1, §9]` | none held | one HTTP request per atom would pass 500 requests/min per server at 8.3 atoms/s |
| (b) **batches pushed to a callback** | 0.66–0.71 µs per batch of 16, plus one resume per connection (measured) | at most `telemetry.batch` atoms per (player, definition) | matches the export unit; bounded |
| (c) pull | a copy per call | atoms held until game code asks: unbounded, or dropped unseen | right for streams, wrong for atoms |

- **Choice: (b) for atoms, (c) for streams** `[checks-telemetry T2]`. Atoms are events with a moment and a fixed size,
  so bounded pushed batches keep memory bounded and give game code its export unit. A stream at 60 Hz × 12 B is
  720 B/s per player, 72 KB/s at 100 players; pushing it would hand game code all of it with no moment to cut at, so
  game code copies a ring when it decides to (a report filed, a round ended).
- **Batch close:** at `telemetry.batch` atoms; at `telemetry.seconds` after the batch's first atom (checked once per
  flush); when the player leaves (pending atoms complete as partial first; `v5.md` §5.1 flushes the leaving player's
  frame before); at `BindToClose`, for every open batch. Game code that exports must finish its HTTP within the
  shutdown window, which is Roblox's limit.
- **Delivery rules**, as observers (`v5.md` §7.3): each connection is called in a pooled thread, so a throwing
  callback is reported natively and a yielding one holds only itself; the batch table and its layout are frozen;
  each connection receives its own copy of the buffer, which it owns, may keep and may send.
- **Streams:** `Lync.telemetry.read(player, Net.look)` returns a copy of the ring, oldest first, with the anchor
  `serverTime` (`GetServerTimeNow()` at the call) and `ms` (⌊`os.clock()` × 1000⌋ mod 2^32 at the call), so an
  entry's server time is `serverTime` − ((`ms` − entry.`ms`) mod 2^32)/1000; nil when the player has no ring. One
  buffer copy of at most `ring` × E bytes.
- **Counters** (`v5.md` §7.4): `atomsDelivered` and `atomsSkipped`, per definition. Atoms raise no fact: an atom has
  no trigger beyond "a message arrived".

### 8.6 API and types

```luau
-- server
Net.look:field("dir"):aim()                           -- look: from = "client", data = { dir = t.direction(11) }
Net.strike:series()                                   -- timing only
Net.strike:atom({ before = 0.5, after = 0.25, fields = { "origin", "target" }, series = Net.look })
local connection = Lync.telemetry.atoms(function(batch: Lync.AtomBatch)
	Export.queue(batch.player, batch.definition, batch.data) -- game code (§8.8)
end)
local look = Lync.telemetry.read(player, Net.look)    -- a copy of the ring, or nil
```

Types are plain records with no `read` modifiers, since the old solver rejects them in generated shards (`v5.md`
§3.2); the tables are frozen at run time (the layout and its `fields` too). `aim` and `series` are methods of the
field handle `Field<D, T>`, present only where T is a codec they take; `atom`'s `fields` is typed as a union of the
definition's numeric paths.

```luau
export type AtomBatch = {
	player: Player,
	namespace: string,
	definition: string,
	count: number,       -- atoms in data
	layout: AtomLayout,  -- one per atom declaration
	data: buffer,        -- count atoms, layout version 1
}
export type AtomLayout = {
	version: number,     -- 1
	fields: { string },  -- value names in order: "origin.x", "origin.y", "origin.z", "target"
	entry: "timing" | "aim" | "scalar" | "vector" | "none",
	entryBytes: number,  -- 8, 12, 12, 20 or 0
}
export type Stream = { layout: AtomLayout, count: number, data: buffer, serverTime: number, ms: number }
```

`Lync.telemetry.decode(batch): { Atom }` turns a batch into tables (`{ serverTime, key, flags, fields: { [string]:
number }, samples: { { dt, key, yaw?, pitch?, value?, vector? } } }`, `dt` in seconds) for game code that analyses in
process; a cold path that allocates per atom. roblox-ts, from the same IR (dot calls, `this: void`, `readonly`
fields):

```ts
interface ServerEvent<T> {
	series(this: void, options?: { ring?: number }): void; // timing only
	atom(this: void, options: { before?: number; after?: number; fields?: ReadonlyArray<NumericPath<T>>;
		series?: ServerEvent<unknown>; pending?: number }): void;
}
interface Field<D, T> { // aim on aim codecs, series on value codecs
	aim(this: void, options?: { ring?: number }): void;
	series(this: void, options?: { ring?: number }): void;
}
declare namespace telemetry {
	function atoms(this: void, fn: (batch: AtomBatch) => void): Connection;
	function read(this: void, player: Player, def: ServerEvent<unknown>): Stream | undefined;
	function decode(this: void, batch: AtomBatch): ReadonlyArray<Atom>;
}
```

`NumericPath<T>` is emitted per definition as a literal union, never computed by type-level recursion. Caller
errors: `unknownField`, `fieldKind` (the codec isn't one the call takes),
`telemetryTwice`, `seriesMissing` (`series =` a definition with neither `:aim` nor `:series`), `viewPlacement`, and
the option codes of §10.

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
- **No user ids and no client text in the data.** A batch carries the `Player`; the buffer carries no id. Atoms and
  series take numeric codecs only, so a batch can't carry chat or any other text a player typed.

### 8.8 The export recipe (docs)

One `Lync.telemetry.atoms` connection appends each batch to a buffer behind a header the recipe fixes (version u8,
namespace and definition as u16-length strings, the exported player key as f64, count u16), and sends the buffer every
2 s with one `HttpService:RequestAsync` whose `Body` is `buffer.tostring(…)` (a body "can be any string, including
binary data", documented, `HttpService.yaml`), retrying with backoff (documented best practice).
- At 100 players × 2 atoms/s × 591 B, that is 118 KB/s: 30 requests/min of 236 KB each (derived).
- A request body limit is not documented (`HttpService.yaml` and `http-service.md` searched for "size", "limit",
  "MB", "body"): unverified (§11). The recipe takes a byte limit as a parameter and splits the buffer at it.
- `PostAsync`'s `compress` argument gzips the body (documented); `EncodingService`'s Zstd is the other route.

### 8.9 Known causes in the samples of an unmodified client

`checks-telemetry/telemetry_samples.out`, a model: `v5.md` §9's network, frame times drawn per case, not measured on
devices. Flush rate by reading of `v5.md` §5.1's rule ("reset": time since the last flush; "carry": an accumulator
that keeps the remainder):

| Case | Flushes/s, reset | Flushes/s, carry | Server inter-arrival under reset, mean ± sd (ms) | Aim entries per 0.75 s, min / mean / max (reset) |
|---|---|---|---|---|
| 30 FPS, low-end mobile | 29.1 | 29.1 | 35.9 ± 12.5 | 15 / 20.8 / 24 |
| 45 FPS, GPU-bound | 44.1 | 44.1 | 23.9 ± 10.5 | 25 / 31.4 / 35 |
| 60 FPS cap, steady | 40.0 | 60.0 | 26.3 ± 13.1 | 21 / 28.5 / 35 |
| 120 FPS cap | 47.8 | 60.0 | 22.0 ± 10.4 | 26 / 34.2 / 40 |
| 144 FPS cap | 47.8 | 60.0 | 22.0 ± 9.5 | 27 / 34.1 / 37 |
| 240 FPS cap | 53.3 | 60.0 | 19.8 ± 9.5 | 32 / 37.9 / 42 |

The docs state each cause, so analysis doesn't read them as anything else:
1. **Frame rate sets the sample rate** (29–60 Hz across devices), so analysis by index is wrong on every device;
   every entry carries its time and atoms their count `n`. Which reading `v5.md` §5.1 takes is the runtime unit's
   (this table supports the carry reading's 60 Hz).
2. **The network dominates timing:** server-side sd 9.5–13.1 ms against client flush sd 0.8–8.4 ms; a timing series
   resolves a hand only at intervals well above 20 ms.
3. **Game code produces machine-regular timing:** a script firing "if now − last ≥ 0.1" sends at intervals fixed by
   its frame grid (at 60 FPS only 83, 84, 100, 101, 116, 117 and 133 ms; seen at the server as 108.4 ± 15.6 ms).
   Automatic weapons, auto-collect and cooldown loops give the same low variance.
4. **Loss and late frames:** 5% loss leaves gaps of 90–182 ms in a window; in arrival order 0.53% of aim deltas run
   backwards at 0.02 s jitter (13.5% at 0.05 s), in key order none. Analysis sorts by `key`.
5. **Yaw near the poles:** one `t.direction(10)` step moves yaw by up to 0.24° level, 1.4° at 80° pitch, 13.6° at
   89°, 180° at 89.9°. Analysis uses the angle between reconstructed directions, never yaw differences; the docs
   give the formula.
6. **Input devices** (unverified, general behaviour): gamepad sticks turn at a rate; touch moves in swipes; mouse
   flicks stop sharply; VR follows the head. No single rule tells them from automation.
7. **The game's own camera code:** lock-on, aim assist, aim-down-sights snaps, recoil, shift-lock, respawn and
   teleport resets, cutscenes, seats.
8. **Quantization:** the aim codec's error (0.2369° at `t.direction(10)`) is far above the export's 0.0055°.
9. **Truncated and partial atoms:** truncated after join, or when frames of the series definition exceed
   `ring`/(`before` + `after`) per second (85.3 at the defaults); partial on leave.
10. **Server load:** arrival time is when Lync's handler runs, so a server frame hitch stamps several frames with
    nearly one time (magnitude unverified, §11).

**How it is defeated.** A modified client controls every value it sends and when; it can shape aim and timing like
any device. Telemetry raises the cost of crude automation and gives evidence for review; it proves nothing about one
player.

### 8.10 Options, memory and cost

| Option | Where | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|---|
| field | `field(path):aim` | field handle | — | a `t.direction`, `t.rotation`, `t.cframe` or `{ yaw = t.angle, pitch = t.angle }` field | — | 65–73 ns native, 221–228 ns interpreted per sampled frame from a decoded direction; the record form adds four trigonometric calls (unmeasured) |
| field | `field(path):series`, or `series` on the definition for timing only | field handle or none | — | a codec of §8.2's values | none: timing only | timing: 22–24 ns native, 91–93 ns interpreted per sampled frame; values: unmeasured (§11) |
| `ring` | `:aim`, `:series` | integer | entries | 16–1024 | 64 (chosen: at least the 45 entries of the default window at 60 frames/s; atoms truncate above 85.3 frames/s) | E × `ring` per player: 768 B for aim at 64 |
| `before` | `:atom` | number (real) | s | 0–2 | 0.5 (the reported VACnet window `[anticheat-design §5.1]`) | needs `ring` ≥ (`before` + `after`) × the series' frames per second, else bit 1 |
| `after` | `:atom` | number (real) | s | 0–1 | 0.25 (VACnet, as `before`) | a pending slot held `after` s plus up to one server frame |
| `fields` | `:atom` | array of string | — | paths of §8.2's value codecs on the atom's definition, at most 16 values (a vector counts 3) | `{}` | 8 B per value per atom; trigger 35–38 ns native, 151–163 ns interpreted for 5 values |
| `series` | `:atom` | a definition with `:aim()` or `:series()` | — | — | nil: no entries | completion 252–260 ns native, 477–506 ns interpreted per atom of 46 entries |
| `pending` | `:atom` | integer | atoms per player | 1–64 | 8 (chosen: sustains 8/(`after` + 1/60 s) = 30 atoms/s per player at the default `after`; a definition firing faster needs more) | (19 + 8 · F) B each |
| `telemetry.batch` | `Lync.configure` | integer | atoms | 1–256 | 16 (chosen: the hand-off is 41–44 ns per atom amortised at 16; a larger batch holds more memory per player) | at most `batch` × the atom size held per (player, definition); 0.66–0.71 µs per hand-off plus 88–131 ns per connection |
| `telemetry.seconds` | `Lync.configure` | number (real) | s | 1–600 | 30 (chosen: equal to `observe.window`'s default, so an atom reaches game code no later than a coalesced fact) | an open batch is held up to this long |

- **Memory per player** (derived from the layouts): aim ring 768 B, timing ring 512 B, vector ring 1,280 B at 64;
  pending 8 × 51 B = 408 B for 4 values; batch buffer 16 × 591 B = 9.5 KB for 45-entry windows, at most
  16 × (51 + 64 × 12) = 13.1 KB. One aim series, one timing series and one atom declaration: at most 14.8 KB per
  player, 1.48 MB for 100 players. Allocated at the player's first sampled message, freed on leave.
- **Cost** (measured on the research's 4 B and 8 B layouts, `checks-telemetry/telemetry_cost.out`; the widened
  fields of §8.2 are the same number of buffer writes and copy 4 B more per entry, unmeasured): 100 players at 60 aim
  samples/s is 0.39–0.44 ms/s native and 1.3 ms/s interpreted; two atoms per player per second add 0.06 ms/s native
  and 0.13 ms/s interpreted, the batches about 0.01 ms/s. Wire 0 B: Lync samples traffic the game already sends (an
  aim stream needs the game to send its look direction, 22 bits per message for `t.direction(11)` plus framing).
- **Not sampled:** server-sent traffic, anything on the client, and `Player:GetCameraState()` (server-side camera
  under Server Authority, documented), which isn't traffic Lync decodes.

### 8.11 What Lync's docs must tell developers about Roblox's terms

One page, linked from the telemetry reference, quoting each source `[checks-telemetry T3]` (read 2026-10-15; the
readings are the research's, unverified, and not legal advice):
- **Sources it quotes:** the current Creator Terms §14.b (Experience Data), §14.c (User PII), §14.d; the Creator Terms
  in force from 2026-11-01, §3.9 (Game data) and §5.4 (personal information); the Privacy and Cookie Policy's
  definition of personal information; the Community Standards' ban on "programmatic calls to third-party advertising
  and measurement services"; `RTBF-and-creators.md`, `automate-right-to-erasure.md` and `players/users.md`. Until
  2026-11-01 the page cites both versions of the Creator Terms.
- **What it says:**
  - exported telemetry is personal data under the Privacy Policy; Lync puts no id in the buffer, and the key game
    code adds makes it personal;
  - use it for the purposes the terms name: security, fraud prevention, improving the game;
  - send it to systems you control, over HTTPS (the only scheme `HttpService` allows), with credentials in Secrets;
  - never to advertising or measurement services; sending it to any other third party is restricted (current §14.b,
    §5.4 from 2026-11-01): read the clause and decide; Lync can't decide it for you;
  - don't sell or share it, join it to other personal information, or use it to build cross-platform profiles;
    quote §14.c(ii) and §5.4 on records about an individual user without interpreting them as permission;
  - protect it from unauthorized access (§14.d, §5.4);
  - set a retention period, and delete a player's telemetry on every erasure request (webhook or daily message),
    keyed by `Player.UserId`, which is domain-scoped for players who first joined after the rollout, so the request's
    id finds it;
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
  doesn't hold, so readers of memory, packets and state, and accounts sharing artefacts, face 2^63 expected key
  trials per seal; HalfSipHash with c ≥ 2, d ≥ 4 "is expected to provide the maximum PRF security" for its key and
  output size (documented, the SipHash README). Unlike every measure in `v5.md` §6.2, its secret is not on the client
  before the reveal.
- **Doesn't protect:** anything after the reveal (every client gets the plaintext then, a modified one no sooner);
  the time and count of seals; whatever the server's own behaviour discloses; the length, when `hideLength` is false.
  Only server-side code can defeat it, by revealing early or sending the value elsewhere.

### 9.2 Declaration and API

```luau
-- shared schema
nextRound = Lync.event({ from = "server", data = Layout, sealed = { outstanding = 1 } }),
-- server
local seal = Net.nextRound:fire(Lync.all, layout) -- returns a Seal for a sealed definition
-- … when the round starts
seal:reveal()                                     -- or seal:discard()
-- client: unchanged; the handler runs at the reveal with the decoded value
Net.nextRound:connect(function(layout) end)
```

- **`sealed`** is a definition option of server-sent reliable events, in the shared schema and hashed (the client
  must decrypt). On a client-sent event, a request, a collection or the unreliable lane it is the declaration error
  `optionPlacement` (`v5.md` §3.4); a `data` reaching a `t.instance` is `sealedInstance`, since instances travel in
  the frame's instance array in the clear (`v5.md` §4.2) and can't be sealed.
- **`fire`** on a sealed definition returns a `Seal` with `reveal()` and `discard()`; calling either on a seal
  already revealed or discarded throws `sealSettled`. Generated path: `fire`'s return type is `Seal` for sealed
  definitions; runtime path: a type function on the presence of `sealed` in the definition's table type, under the
  new solver (unverified until milestone 1's typing proofs, `v5.md` §3.5, §11). roblox-ts: `fire(this: void, target,
  data): Seal`.
- **Client types** are unchanged: `connect` handlers receive the decoded value at the reveal.

### 9.3 Wire

Each message of a sealed definition is one row (`v5.md` §4.3's runs):

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
- **Size.** A sealed message's worst case is 8 × ⌈W/8⌉ B of tail plus a header of at most 2 + 107 + the EG-0 length
  of ⌈W/8⌉ bits; `messageTooLarge` applies to it. A reveal is 2 bits + the seal id's EG-0 + 64 bits: 67 bits for id 0,
  at most 79 bits for ids below 127 (derived); a discard is 2 bits + the id's EG-0.
- **Encode once.** One key per seal, not per viewer: a seal's chunk and its reveal are identical for every recipient,
  so they are shared chunks and stay eligible for `FireAllClients` (`v5.md` §4.2). Per-player values are separate
  fires.
- **Schema hash:** `sealed` joins `v5.md` §4.7's option list after `reliableRate` (presence u8, then `outstanding`
  `num` and `hideLength` u8); the wire unit owns the serialization numbering (§10). Golden frames at seed 0 without
  `sealed` don't change.

### 9.4 Keys

- **Server secret S** (64 bits): two `NextInteger(0, 2^32 − 1)` draws from a `Random.new()` instance created without
  a seed (internal entropy source, documented, creator-docs `datatypes/Random.yaml`), used for nothing else, drawn at
  the server's first sealed send and never sent. Roblox does not document `Random` as cryptographic (unverified,
  §11); S is never sent, and a revealed key is one PRF output under it, not generator state.
- **Seal key** K_i = HalfSipHash-2-4/64 under S over (d as u32le, i as u64le), with d the server's number for the
  definition (sealed definitions numbered from 0 in order of first sealed send) and i the definition's seal counter
  from 0 on this server, which is also the wire `seal` id. Keys are computed at the reveal, so the server stores no
  key.

### 9.5 Recipients and `outstanding`

- **Recipients** are the seal's target resolved at the flush that encodes it (`v5.md` §3.5); a player in the join
  hold receives it from the hold, as any send (`v5.md` §5.3). A player who joins later doesn't receive it.
- **Outstanding** counts, per (player, definition), seals queued to that player and not yet revealed or discarded.
  A recipient already at `outstanding` is skipped for that seal, which never reaches them, and the server records
  the local fact `sendDropped` with `cause` 5.
- **`reveal()` and `discard()`** queue the reveal or discard message, in call order, to the seal's recipients still
  connected; called before the seal's own flush, both leave in the same flush after it. Each decrements the
  recipients' counts. A leaving player's counts are freed.

### 9.6 Client decode

- The client holds, per sealed definition, at most `outstanding` seals (id → ciphertext).
- **Refused with a `v5.md` §4.8 rule:** `kind` 3 (rule 2); a seal while `outstanding` are held, or `blocks` above ⌈W/8⌉
  (rule 2); with `hideLength`, `blocks` other than ⌈W/8⌉ (rule 3); a seal id already held, or a reveal or discard
  naming no held seal (rule 7).
- **At the reveal** it decrypts and decodes the plaintext under `v5.md` §4.8 (padding bytes past the encoding must
  be zero, rule 4); a violation refuses the frame holding the reveal. Refusals are counted in `refusedFrames` and sent in
  `REPORT`, as for any downstream frame (`v5-integrity.md` §5). The value is then delivered to `connect` handlers
  at the reveal's place in run order, and the ciphertext is freed; a discard frees it.

### 9.7 Fact, options and cost

| Reason | Exact trigger | Action | Evidence | Known causes on an unmodified client |
|---|---|---|---|---|
| `sendDropped`, `cause` 5 | local: a sealed send to a recipient already holding `sealed.outstanding` unrevealed seals of that definition | the send to that recipient is dropped | `cause`, `bytes` | game code sealing faster than it reveals or discards, or dropping a `Seal` without calling either |

Nothing sealed flows upstream, so there is no other server fact.

The options `sealed.outstanding` (integer, unrevealed seals per player per definition, 1–256, default 1, chosen)
and `sealed.hideLength` (boolean, default true) are rows of `v5.md` §3.4's option table, the one home for definition
options, with their costs: the client holds up to `outstanding` × 8 × ⌈W/8⌉ B per sealed definition and the server
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
- **Fact:** `constraint` (§1.5); `sendDropped` gains `cause` 5 (§9.7).
- **Declaration:** `rolePlacement` (§7.1, `v5.md` §3.3), `sealedInstance` (§9.2); `sealed` where the definition
  doesn't take it is `v5.md` §3.4's `optionPlacement`.
- **Caller:**
  - `fieldKind`: a check or telemetry call on a field handle whose codec that call doesn't take (`v5.md` §7.1 uses
    it for every call that names a field);
  - `checkPool`: two `maxTotal` checks in one pool with different `cap` or `seconds`;
  - `viewPlacement`: a check or telemetry call on a definition outside its scope (§1.2, §8.1);
  - `telemetryTwice`: a second `aim` or `series` (on the definition or any of its fields), or a second `atom`, on
    one definition;
  - `seriesMissing`: an atom's `series` names a definition with neither an `aim` nor a `series`;
  - `sealSettled`: `reveal()` or `discard()` on a seal already revealed or discarded;
  - `claimUnverified`: `connect` or `handle` on a definition with an unverified claim leaf (§7.3, `v5.md` §3.3);
  - `unknownCallOption`, `missingCallOption`, `callOptionRange`: `v5.md` §7.1's set for every run-time options
    table, used by every call here;
  - `unknownField` (`v5.md` §3.4) for a path naming no field.
- **Build:** `freeFormField` (`v5-tooling.md` §3.4).
- **Counters** (`v5.md` §7.4), per definition: `checksSkipped` (a `reference` or `fn` returned nil),
  `checksExempted` (a message inside a `resetChecks` window, §1.6), `atomsDelivered`, `atomsSkipped` (§8.5).
- **Configuration** (`Lync.configure`, `v5.md` §7.5): `telemetry.batch`, `telemetry.seconds` (§8.10).
- **Runtime constant:** `maxTotal` buckets, 16 (§4.1).
- **Schema hash** (`v5.md` §4.7): codec type 26 `role` (§7.1); the `sealed` option (§9.3).

## 11. Pending measurements and proofs

Each has a default or a rule the design uses; none blocks the milestone.
- Roblox's server build for checks and telemetry, and whether a Roblox server runs Lync's modules native; state
  lookup by `Player` against the probes' slot index.
- `Random:NextInteger` on Roblox servers (`oneIn`, §5.2), and whether `Random` is cryptographic (S, §9.4).
- The engine's downstream rate per player (sealing against withholding, §9.1); HalfSipHash over 12 B (§9.7).
- The engine's replication delay for client-owned physics (`within` cause 1); jitter on mobile networks (the c of
  the docs' `burst` derivation, §6.2).
- Whether `GetServerTimeNow()` can decrease on a client, and whether the device clock can be set back
  (`monotonic` cause 4).
- Cross-device float results on arm64 clients, and FP contraction in Roblox's arm64 interpreter (`derive` cause 1).
- `Workspace:Raycast` cost inside a `fn` (`oneIn`'s use).
- Telemetry: the value-series cost, the record-form aim cost and the widened layout (§8.10); real frame-delta
  noise at a 60 FPS cap; the server-load timing burst (cause 10); the HTTP request body limit (§8.8); the three
  terms sources of §8.11.
- Typing proofs (`v5.md` §10): the runtime path's field handles for nested paths, and its type for a sealed `fire`
  (§9.2).
