# `checks` (D3), the free-form field lint (U12), and telemetry

Researcher brief, 2026-10-15. Design research for Lync v5; no library code. Item numbers D3 and U12 are from
`research/security-refusals.md` §3–§4. This file designs the `checks` extension that `design/v5-extensions.md`
left to milestone 7, and the U12 lint. A later unit appends telemetry.

**Read in full:** `design/v5.md`, `design/v5-extensions.md`, `design/v5-integrity.md`; `research/anticheat-design.md`
§3–§4 (claims and constraints) and Implications; `research/diagnostics.md` §2, §4, §5 (codes, channels, facts).
Also read: `design/v5-changes.md` (M4, M8, R8, "Deferred"), `design/v5-tooling.md` §3, `research/security-refusals.md`
§1–§4. Cited as `v5.md §n`, `INT §n` (`v5-integrity.md`), `AC §n` (`anticheat-design.md`), `DIAG §n`.

**Labels:** **verified** (I ran it or read the source), **documented** (official docs), **reported** (third
party), **unverified**. Costs are **measured** (a probe here), **derived** (arithmetic from stated inputs) or
**asserted**.

**Tools.** Luau 0.742 built from `.data/projects/luau` (CMake Release; scratch build, not committed), interpreted
`-O2` and native `-O2 --codegen`, on an Intel Xeon 2.1 GHz (4 cores). The checks run on the server, where Roblox
compiles natively only what is marked `--!native`, so both figures are given. CLI timings indicate scale; Roblox's
server build is not measured. Type checks of the probes: luau-analyze 0.740 (the skill's pinned analyzer), clean.

**Probes** (`.data/docs/probes/checks-telemetry/`):
- `checks_cost.luau` → `checks_cost.out`: raw kernels, and the checks through a table-driven runner (3 process
  runs per mode, best of 7 per line). Fixed here: the atom-copy line ran N/10 copies but divided by N.
- `monotonic_reorder.luau` → `monotonic_reorder.out`: `monotonic` on the unreliable lane under v5.md §9's network.
- `maxtotal_bounds.luau` → `maxtotal_bounds.out`: what a sliding window and a token bucket bound.
- `lint_freeform.luau` → `lint_freeform.out`: a prototype of the U12 rule over stand-in codecs.

## Checks

- [x] C0. Common frame: where checks are declared, where they run, policies, the `constraint` fact
- [x] C1. `within`
- [x] C2. `monotonic`
- [x] C3. `maxTotal`
- [x] C4. `:claim()` (and `:input()`)
- [x] C5. U12: the free-form field lint
- [x] C6. Cost probe: the fix and the results
- [x] C7. Implications (checks and U12)

### C0. Common frame

**What the docs fix already** (documented in the design): checks are `within`, `monotonic`, `maxTotal`, each with a
failure policy of `drop` or `clamp`; every failure is the fact `constraint`, with the policy in its evidence;
`:claim()` is a bare marker, and a definition with claim fields must have `validate` (`v5-extensions.md:24-27`;
M8 and R8 in `v5-changes.md:32,65`). `maxRate`, `planar`, `exempt` were dropped with no reason recorded, and
`cooldown` folded into `limit` (`security-refusals.md` R35). The research's draft (AC §4.2) had per-modifier state
of 0–16 B and "27–49 ns native" for a bucket, a cooldown and a monotonic check together.

**Decision: where checks are declared.**
- Options: (a) codec methods in the shared schema (`t.int(0, 1000):maxTotal(5000, 600)`); (b) **server-view
  calls**, like `:trap()`, `:refers()`, `:canary()` (INT §3, §8, §9).
- Choose (b). `within` needs a server-state reference, which is a function, and functions can't live in a
  shared schema the client evaluates. Bounds stay off the client: the server shard is never replicated (v5.md
  §3.5), so a modified client can't read the tolerance and use exactly all of it. Checks change no bytes, so
  they stay out of the hash (§4.7) and a retune needs no client rebuild. `:claim()` stays a codec method in the
  shared schema, because the planner and the U12 lint have to see it (C4, C5).
- Shape: `Net.<definition>:<check>(path, options)`. `path` names a field of `data` with dots through records and
  optionals (`"origin"`, `"hit.origin"`); `""` names `data` itself when it isn't a record. Arrays, maps and union
  variants are out of scope (`checkKind`). A check on an optional field that is absent from a message is skipped.
  The generated server shard types `path` as a union of the literal paths a check accepts; on the runtime path it
  is a string checked at the call.
- Checks apply to `data` of client-sent events and of client requests' asks. Replies to server `invoke`s are
  not covered: Lync has no validator step for answers, and the code calling `invoke` checks the result.
- A check may be declared at any time; it applies to messages decoded after the call. A check's index is its
  1-based position among that definition's checks in declaration order; the fact reports it.

**Caller errors** (family `caller`, thrown at the caller, v5.md §7.2): `unknownField` (exists: a path that names
no field), `checkKind` (the field's codec isn't one the check takes, or `clamp` where the check can't clamp),
`checkOption` (an unknown, missing or out-of-range option), `checkPool` (two `maxTotal`s in one pool with
different `cap` or `seconds`).

**Decision: policies.** `policy` is required, with no default, because a default would be Lync choosing to drop.
- `"drop"`: the message is dropped and counted; an ask is answered `rejected` (the outcome a `validate` refusal
  gives, v5.md §5.2).
- `"clamp"`: the value is replaced by the nearest value the check accepts (defined per check), then delivered.
- `"deliver"` (new): the message is delivered unchanged. This isn't in `v5-extensions.md`. It follows R25's rule
  for inferred reachability, early answers, decoys and canaries (delivered and reported), and it lets a game set a
  tolerance from real traffic before it drops anything.
- Every failing check is reported as `constraint`, whatever the policy.

**Where it runs** (`v5.md` §6.1). Step 5 becomes: control; traps and reachability; answers; `unresolved`;
`limit`; **checks**; then the report-only checks of milestone 5. Step 6 gains a commit.
1. **Evaluate.** For each message, every check of its definition runs in declaration order, each seeing the
   values left by earlier `clamp`s. Every failure is recorded (one `constraint` occurrence each). If any failing
   check has `drop`, the message is dropped and nothing is committed.
2. **Validate** (step 6) sees the clamped values. A reference function (`within`) runs inside the same `xpcall`
   as the validator. A throw or a yield is reported as `validatorError` or `validatorYielded`, under the same
   spacing as validators, and the message is dropped (an ask is answered `rejected`).
3. **Commit.** Only when the message is delivered (it passed or was clamped, and `validate` returned true or there
   is none) does `monotonic` store its value and `maxTotal` charge its amount. So a message that `validate`
   refuses changes no check state. Messages of one frame are handled in order, each committing before the next is
   evaluated.

Checks run after `limit`, so messages over the limit never touch check state. They run before validators, so a
claim's game-code verifier sees only values that passed or were clamped.

**The fact.** One reason, `constraint`, with one evidence set for all three kinds. This follows `unresolved`'s
pattern (one code, `what` = 1, 2, 3; v5.md §7.3). It keeps evidence narrowing on `reason` alone, the form proven
on both solvers (`[probes review-2 t3]`); narrowing on a nested `kind` is not proven.

| Reason | Exact trigger | Action | Evidence | Known causes on an unmodified client |
|---|---|---|---|---|
| `constraint` | a declared check on the message's definition fails: C1 (`within`), C2 (`monotonic`) or C3 (`maxTotal`) gives the per-kind trigger | by `policy`: dropped (ask `rejected`), clamped and delivered, or delivered | `check` (1-based index on the definition), `kind` (1 `within`, 2 `monotonic`, 3 `maxTotal`), `policy` (1 drop, 2 clamp, 3 deliver), `observed` (`within`: the distance; `monotonic`: the value; `maxTotal`: window sum plus the amount), `bound` (`within`: the max distance applied; `monotonic`: the stored value; `maxTotal`: `cap`), `late` (`monotonic` only: 1 when the message's frame is older than the one that stored the value; else 0) | per kind, C1–C3 |

Evidence holds only numbers, and the values are pre-clamp. A fact never carries client bytes; the numbers come
from the decoded value, as `unresolved`'s `value` does. The key is (player, reason, namespace, definition), so
two failing checks of one definition coalesce, and the window-close fact carries the last occurrence's `check`
(v5.md §7.3).

**Counters** (v5.md §7.4): `checksSkipped` (a `within` reference returned nil), `claimsUnverified` (C4).

**State lifetime.** Per (player, check), or per (player, pool) for `maxTotal`. It is allocated at the player's
first message that reaches the check, freed when the player leaves, and cleared for one player by
`Net.<definition>:resetChecks(player)`. That is the call for game rounds and respawns that legitimately reset a
counter. It resets state; it doesn't open an exemption window like R35's refused `exempt`.

### C1. `within`

**Semantics.** `Net.strike:within("origin", { reference = rootOf, maxDistance = 6, policy = "drop" })`.
- Per message, Lync calls `reference(player, data)`. It returns `(r, maxDistance?)`: the server's value to compare
  against, and optionally a max distance for this message alone (speed × elapsed time, say). If `r` is nil the
  check is skipped and counted (`checksSkipped`).
- The distance d is defined by the field's codec:
  - `t.int`, `t.number`, `t.f32`, `t.f64`: |v − r|;
  - `t.angle`: the wrapped difference, min(δ, 2π − δ) with δ = |v − r| mod 2π;
  - `t.vector3`, `t.vector3f32`: |v − r|;
  - `t.direction`: the angle between them, acos(clamp(v·r, −1, 1)).
- **Exact trigger:** not (d ≤ maxDistance). Equality passes, and a NaN from the reference fails. Decoded values
  are never NaN, because `t.f32` and `t.f64` refuse it (v5.md §3.3).
- **Clamp:**
  - scalars: r + clamp(v − r, −max, max);
  - `t.angle`: r ± max, wrapped into [0, 2π);
  - vectors: r + (v − r) · max/d.
  - Clamped values are not re-quantized. They can lie outside the codec's range only when r does. `t.direction`
    has no clamp (`checkKind`).
- Accepted codecs are the ones listed. A `t.cframe` field, a record, an array and the rest are `checkKind`. A
  check of a `t.cframe`'s position would need a path into the cframe, which this design doesn't define.

**What it protects.** Claims about where something is relative to server truth:
- a shot origin against the shooter;
- reach, a claimed interaction target against the player;
- a client-stated time against `GetServerTimeNow()`;
- a claimed tick against `Lync.tick()`.

A forged value is bounded to the sphere or interval of radius `maxDistance` around the server's value, on every
message. This is AC §4.2's `:within(refField or fn, maxDist)` with the reference made a server function.

**How it fails, or is defeated.**
- **Inside the tolerance.** A modified client can claim any point inside the sphere on every message. The
  tolerance is the advantage it can take.
- **A client-controlled reference.** If the reference is client-controlled, the check compares two client values.
  An example is a character's root part under the client's network ownership, whose position the client sets. The
  check then only tests consistency. That is a fact for the docs, not something Lync can detect.
- **A reference that follows the claim.** Repeated in-tolerance claims add up when the reference itself follows
  them. A position the server accepts from the same client is such a reference.

**Known causes on an unmodified client:**
1. **Latency between the client's value and the server's reference.**
   - The gap is the reference's speed times the time between the client sampling its value and the server
     evaluating it. On the default network that time is one-way latency 0.05 s, plus jitter up to 0.02 s, plus up
     to one client flush (1/60 s) and one server step (1/60 s), about 0.10 s (derived, v5.md §5.1 and §9).
   - At Roblox's default `Humanoid.WalkSpeed` of 16 studs/s (documented, [Humanoid.yaml](https://github.com/Roblox/creator-docs/blob/main/content/en-us/reference/engine/classes/Humanoid.yaml), "defaults to … `StarterPlayer.CharacterWalkSpeed` (`16`)") that is about 1.6 studs. A reliable-lane stall of
     0.85 s (the simulated p99, v5.md §4.9 `limit` slack) adds about 13.6 studs on that lane (derived).
   - For physics the client owns, the server's copy lags by the engine's replication delay, which is not
     measured (AC §4.1, unverified).
   - The `rewind` extension removes this cause for records Lync replicates. There a reference returns the state
     at the client's perceived tick, taken from its newest ack (`v5-extensions.md:21-23`).
2. **Teleports, respawns and seat changes** between send and arrival.
3. **Quantization.** d is measured on decoded values: up to √3·step/2 for `t.vector3` (0.027 studs at step 1/32),
   step/2 for `t.number`, π/n for `t.angle`, and the octahedral error for `t.direction` (0.2369° at 10 bits;
   v5.md §3.3).
4. **A reference that measures something else** than the client's code reads: the camera rather than the root
   part, or a part's centre rather than its surface.

**Least work.** One line per claim on the server, where the game already has a function for the server's truth.
Start with `policy = "deliver"`, read `observed` from the facts over a play session, then switch to `"drop"`. The
docs give the formula: `maxDistance` = speed × 0.25 s plus the quantization error.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `path` | string | — | a field of a codec listed above, reached through records and optionals | required | none |
| `reference` | `(Player, T) -> (R?, number?)`; R is `number` for scalars and `t.angle`, `Vector3` for vectors and `t.direction` | — | — | required | one call per message, inside the validator's `xpcall` (+18–38 ns per message when the definition has no validator, DIAG §9) |
| `maxDistance` | number (real) | the field's unit: studs for positions, radians for `t.angle` and `t.direction` | ≥ 0, finite | required | none; a second return from `reference` overrides it per message |
| `policy` | `"drop" \| "clamp" \| "deliver"` | — | — | required | clamp: 53–63 ns per clamped vector, native and interpreted alike (measured, C6) |

**Cost** (measured, C6; net of the runner's per-message baseline):
- vector field: 50–56 ns native and 101–109 ns interpreted per message;
- number field: 47–49 ns native and 108–116 ns interpreted;
- a failure adds the fact record, 20.5 ns native (DIAG §5.2).
- State: 0 B. Wire: 0 B.

### C2. `monotonic`

**Semantics.** `Net.input:monotonic("seq", { order = "increasing", policy = "drop" })`. The field is a number that a
client never decreases in send order (`"nondecreasing"`, the default) or always raises (`"increasing"`).
- **Frame key.** Each message has a key that orders frames in send order:
  - on the reliable lane, the frame's tag count (v5.md §4.5), which the server already holds;
  - on the unreliable lane, the frame's extended upstream `seq` (§4.4).
  - Messages of one definition inside a frame are in call order (§4.1), so they share a key and are compared in
    order.
- **State:** the stored key s* and value v*, two f64 per (player, check).
- **Exact trigger**, for a value v from a frame with key s:
  - no stored value: never fails;
  - s ≥ s*: v < v* fails for `"nondecreasing"`, v ≤ v* for `"increasing"`. On commit (C0) s* and v* are replaced.
  - s < s* (a late frame, possible only on the unreliable lane): v > v* fails for `"nondecreasing"`, v ≥ v* for
    `"increasing"`. A value sent earlier can't exceed one sent later. Nothing is stored. Evidence has `late` = 1.
- **Clamp** (`"nondecreasing"` only): v is replaced by v*. `"increasing"` with `clamp` is `checkKind`, because no
  next value is defined for reals.
- **Accepted codecs:** `t.int(min, max)`, `t.int()`, `t.number`, `t.f32`, `t.f64`. `t.angle` wraps, so it is
  `checkKind`.

**Why the frame key** (verified, `monotonic_reorder.out`).
- **The run.** v5.md §9's default network was simulated: 60 unreliable frames/s, latency 0.05 s plus uniform
  jitter up to 0.02 s, 5% loss, 10^6 frames, the field equal to the frame index.
- **Late frames.** 1.31–1.33% of delivered frames (12,478 of 950,046) arrive after a newer one; none is 64 or more
  behind, so the replay window delivers all of them. At 0.05 s jitter, 23.6% arrive late.
- **The rules.** A rule that compares against the last accepted value fails on every late frame: 1.3% of
  unmodified traffic, and 23.6% at 0.05 s jitter. The keyed rule fails on none.
- §9 requires that unmodified clients on the default model raise no fact, so the key is required.

**What it protects.** Values a modified client sends back stale through Lync's own API:
- an earlier sequence number, timestamp or idempotency key, re-sent in a new frame. The tag and replay window
  don't stop this, because the frame itself is new.
- claimed times running backwards, such as a lap start stamp earlier than one already sent.

**How it fails, or is defeated.** Any value that rises passes, including a jump far ahead. A client-stated time
therefore also needs `within` against `GetServerTimeNow()`. `monotonic` bounds the direction only.

**Known causes on an unmodified client:**
1. **Game code restarting the value.** A new round, a respawn, or a counter local to a script that restarts. A
   `LocalScript` under `StarterCharacterScripts` is copied into each new character, so its locals start again at
   every respawn (documented: [StarterCharacterScripts](https://create.roblox.com/docs/reference/engine/classes/StarterCharacterScripts)).
   The fix is `resetChecks(player)` at the reset, or keeping the counter in `PlayerScripts`.
2. **A counter that wraps** inside a bounded `t.int(min, max)`.
3. **Quantization merging values.** Two rising values that decode equal (one `t.number` step, or f64 values
   rounding to one `t.f32`) fail `"increasing"`.
4. **A clock that can be set back.** The device wall clock (`os.time()`, `DateTime.now()`) can be set back by the
   user (unverified on Roblox devices). Whether `GetServerTimeNow()` can decrease on a client is not measured.
5. **Not causes:** loss (gaps pass), reordering (the key), duplicates (the replay window drops them, v5.md §4.5).

**Least work.** One line per field. Call `resetChecks` wherever the game already resets the counter.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `path` | string | — | a `t.int`, `t.number`, `t.f32` or `t.f64` field, reached through records and optionals | required | none |
| `order` | `"nondecreasing" \| "increasing"` | — | — | `"nondecreasing"` | none |
| `policy` | `"drop" \| "clamp" \| "deliver"` | — | `clamp` only with `"nondecreasing"` | required | none beyond a store |

**Cost** (measured, C6, net): 57–63 ns native and 175–183 ns interpreted per message. The raw compare is 3.3–5.9 ns
native; the rest is the table-driven runner. State: 16 B per player per check. Wire: 0 B.

### C3. `maxTotal`

**Semantics.** `Net.collect:maxTotal("coins", { cap = 5000, seconds = 600, policy = "drop" })`. It bounds the
running sum of a field's values per player over a window, timed by server arrival on `os.clock()`, never by client
time (R20, R21).

**Decision: the window mechanism** (verified, `maxtotal_bounds.out`; cap 1000, 60 s, a message every 0.05 s for
600 s).

| Mechanism | Largest accepted sum, greedy sender | State per player | Cost, native (net) |
|---|---|---|---|
| (a) **sliding window of 16 buckets** | any 56.25 s (15/16 of the window): 1000 (1.00 cap); any 60 s: 2000 (2.00 cap); long run: cap/seconds | 144 B (16 sums, head, total) | 74–84 ns |
| (b) token bucket, capacity cap, refill cap/seconds per second (the core `limit` shape) | any 56.25 s: 1937 (1.94 cap); any 60 s: 1999 (2.00 cap); any 1 s: 1015 | 16 B | 65–66 ns |
| (c) exact sliding window, a ring of every committed (time, amount) | any 60 s: cap, exactly (derived) | 16 B per message in the window. A definition needs a `limit` to bound it: at 5 messages/s and 600 s, 48 KB per player per check (derived) | not measured |

- **Choose (a).** It bounds any span of up to 15/16 × `seconds` to `cap` exactly, with constant memory and no
  `limit` required. Under (b), a sender can take nearly 2 × `cap` within 15/16 of the window.
- (b) suits the core `limit`, which smooths server work. A rule written "per window" ("5000 coins per 10 minutes")
  means a sum over the window, and that is what (a) bounds.
- (c) is the tightest. It is the option if the lead wants exactly one window; its memory is the price.
- The bucket count, 16, is a runtime constant (chosen: it sets the 1/16 gap between the two guarantees). It is
  not an option.

**Exact trigger.**
- Let w = `seconds`/16 and k = ⌊`os.clock()`/w⌋ at evaluation, and let S be the sum of amounts committed for
  (player, check or pool) in buckets k − 15 … k. The check fails when S + v > `cap`.
- **Guarantee** (derived, and measured above): any span of 15/16 × `seconds` or less holds at most `cap` of
  committed amounts; any span of `seconds`, at most 2 × `cap`; the long-run rate is at most `cap`/`seconds`.
- **Clamp:** v is replaced by max(0, `cap` − S), rounded down for a `t.int` field, and committed.
- **Accepted codecs:** `t.int(min, max)` and `t.number` with min ≥ 0. `t.int()`, `t.f32` and `t.f64` admit
  negative values, and a negative amount would refund the window, so they are `checkKind`.
- **`pool`:** checks with the same pool name, on any definitions, share one window per player. An example is coins
  from `collect`, `sell` and `quest`. They must declare equal `cap` and `seconds` (else `checkPool`).

**What it protects.** The rate of gain of client-claimed amounts: currency, experience, items or damage carried in
a claim field. This is Roblox's documented "Rate of Gain" heuristic (AC §4.2). A forged stream is bounded to `cap`
per 15/16 window and `cap`/`seconds` in the long run.

**How it fails, or is defeated.**
- A modified client can claim exactly the allowance every time.
- Amounts spread over definitions that aren't in one pool get one cap each.
- It is no substitute for computing the gain on the server, which needs no check at all.

**Known causes on an unmodified client** (`maxtotal_bounds.out`):
1. **A cap below what play produces** within 15/16 × `seconds`: a bonus event, a purchase that doubles rates.
2. **The stream sitting at the cap.** At exactly `cap`/`seconds`, the window reaches `cap` and refuses at bucket
   edges: 10 of 12,000 amounts with no stall, and 84 with one 5 s reliable stall.
3. **Not causes:**
   - stalls with headroom: at 90% of `cap`/`seconds`, no refusal with a single stall of 0, 0.85, 2 or 5 s, for (a)
     or (b);
   - lost messages, which are never charged;
   - messages `validate` refuses, which are never committed (C0).

**Least work.** One line per claimed amount, with the game's own economy rule as `cap` and `seconds`, and 10%
headroom per the measurement.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `path` | string | — | a `t.int(min, max)` or `t.number` field with min ≥ 0, reached through records and optionals | required | none |
| `cap` | number (real) | the field's unit, per window | > 0, ≤ 2^53 | required | none |
| `seconds` | number (real) | s | 1–3600 | required | bucket width `seconds`/16 |
| `pool` | string or nil | — | 1–64 B | nil: the check's own window | one window per player per pool instead of per check |
| `policy` | `"drop" \| "clamp" \| "deliver"` | — | — | required | none |

**Cost** (measured, C6, net):
- 74–84 ns native and 240–248 ns interpreted per message. A message that crosses into a new bucket also clears up
  to 16 sums; the probe includes that at the rate it occurs.
- State: 144 B per player per check or pool. Wire: 0 B.

### C4. `:claim()` and `:input()`

**Semantics.** Two codec methods in the shared schema. Both are non-generic and return the same codec type (v5.md
§3.3's rule): `t.int(1, 2 ^ 40):claim()`, `t.string(200):input()`.
- **Roles.** A leaf is *input* (the client's own control or choice) or *claim* (what the client asserts about the
  world: a hit target, a shot origin, an amount gained, a completion time; AC §3.2).
  - Unmarked leaves are inputs (`v5-changes.md` M4).
  - A leaf's role is the nearest marker on it or on a codec enclosing it within the payload. So `{ … }:claim()`
    marks a whole record, and an inner `:input()` overrides it for its own leaves.
- **Placement.** Markers are allowed only in client-sent payloads: `data` of `from = "client"` events and
  requests, and `reply` of `from = "server"` requests. Anywhere else (server-sent `data`, a client request's
  `reply`, collection fields) is the declaration error `rolePlacement` at the definition's line.
- **Decision: hashing.**
  - (a) Not hashed. That makes an exception to "every value in the schema goes into the schema hash" (v5.md
    §3.4).
  - **(b) Hashed** as a wrapper codec, type 26 `role`: role u8 (1 input, 2 claim), then the codec (§4.7).
  - Choose (b). There is no exception, and it costs 2 B of hash input per marker and nothing at run time. A
    changed role gives `MISMATCH` between builds, and those never meet in production, since both sides' shards come
    from one build run (INT §2).
- **The server requirement.**
  - A claim leaf in `data` is *verified* when the definition has a validator, or when at least one check (C1–C3)
    is declared on that leaf or on a record that encloses it.
  - This departs from `v5-extensions.md`, which requires `validate`: here a check also counts, so
    `Net.strike:within("origin", …)` alone verifies a shot origin.
  - Lync keeps one flag per definition, "has an unverified claim", and recomputes it whenever `validate` or a check
    is declared. Per message, that costs one boolean test.
- **Exact trigger and action.**
  - A message of a definition whose flag is set is dropped at step 6, before validators (an ask is answered
    `rejected`), and counted (`claimsUnverified`).
  - It is also reported natively as **`claimUnverified`** (family `fault`), at most once per definition per
    `observe.window` (v5.md §7.2 spacing). The message is
    `[Lync] claimUnverified: arena.strike data.target must have a validator or a check, got none`. It carries no
    fix, since there are two (§7.1: a fix only when there is exactly one).
  - It is a fault rather than a fact because its cause is the game's declarations, not what a player sent.
  - Known causes: none on the client side. On the server, game code declares neither, or declares them after the
    definition's first messages arrive.
- **Replies** of server requests can carry markers for the lint (C5) but have no run-time requirement, since
  answers have no validator step (C0).
- **Types:** unchanged; a marker doesn't change `T`.

**What it protects.** Nothing by itself at run time, and it raises no fact of its own (a validator returning
`false` stays counter-only, v5.md §7.2).
- **What it guarantees:** no message holding a claim reaches `connect` or `handle` without passing a game
  validator or a Lync check. This is AC §3.2's "the handler only runs after every claim passes", with the verifier
  kept out of the shared schema (M8).
- **What it adds:** it is the link that turns the lint (C5) into protection. A flagged field gets `:claim()`, and
  then the server has to verify it.
- **What defeats it:** a validator that returns `true` unconditionally, which Lync can't tell apart, and marking a
  claim `:input()` to silence the lint.

**`:input()`** has one effect: it silences U12 on a free-form leaf (C5). Every unmarked leaf is already an input.

**Least work.** One marker per claim field in the schema, plus the one server line that verifies it, which the
game needs anyway.

```luau
-- shared schema
strike = Lync.event({ from = "client", lane = "unreliable", data = {
	target = t.int(1, 2 ^ 40):claim(), origin = t.vector3(-2048, 2048, 1 / 32):claim(), aim = t.direction(11),
} }),
-- server
Net.strike:within("origin", { reference = rootOf, maxDistance = 6, policy = "drop" })
Net.strike:refers("target", "fighters") -- INT §8
Net.strike:validate(function(player, s) return Fighters.alive(s.target) end)
```

| Marker | Placement | Default | Cost |
|---|---|---|---|
| `:claim()` | any codec in a client-sent payload | unmarked leaves are inputs | 0 B wire; 2 B hash input; per message one flag test; requires a validator or a check per claim leaf of `data` |
| `:input()` | as `:claim()` | — | 0 B wire; 2 B hash input; no run-time effect |

### C5. U12: the free-form field lint `freeFormField`

**Exact rule.** For each client-sent payload (`data` of `from = "client"` events and requests, and `reply` of
`from = "server"` requests), the planner walks the codec tree depth first in name order:
- it walks into records, `t.optional`, array elements, map keys and values, union variants, `t.convert`'s base,
  and `t.cframe`'s position codec (its rotation is input-shaped);
- it reports one warning per **free-form leaf** that has no role marker on itself or on an enclosing codec (C4).

A leaf is free-form when it is:
- `t.f32`, `t.f64` or `t.vector3f32` (unbounded floats);
- `t.int()` (an unbounded integer);
- `t.int(min, max)` with max − min + 1 > 65,536;
- `t.number(min, max, step)` or `t.vector3(min, max, step)` with n + 1 > 65,536 codes per component (n from
  v5.md §3.3);
- `t.string`, `t.buffer`, `t.instance` or `t.custom`.

Never free-form: `t.bool`, both enum forms, `t.angle`, `t.direction`, `t.rotation`, `t.color3`, and smaller
`t.int` and `t.number`.

The threshold 65,536 (2^16) is a constant, chosen, not measured (below). The research's wording was "free `f64`,
unbounded `str`, `inst` of another player, large ints" (AC §3.2). This rule makes each term exact for v5's
codecs.

**Channel.** A build diagnostic (family `build`; `v5-tooling.md` §3) from `lync build`, `lync check` and, in
milestone 6, the Studio plugin.
- It is placed at the definition's line, which is the line schema constructors record (v5.md §7.1); codec calls
  record none. The field path goes in the message:
  `warning[freeFormField]: arena.strike data.target is client-sent and free-form (integer with 1099511627776 values); mark it :input() or :claim()`.
- Severity follows the `[check]` entry `freeFormField = "warn" | "error" | "off"`, default `"warn"`.
- The runtime path's planner computes it and drops it. On the runtime path there is no build to report to, and a
  line in every session is the channel M11 refused (`v5-changes.md:214`).

**Measured on stand-in codecs** (verified, `lint_freeform.out`):
- **The §3.4 `arena` schema** gives 2 warnings.
  - `chat data` is a false positive: chat text is an input, and gets `:input()`.
  - `strike data.target` (`t.int(1, 2 ^ 40)`) is a true positive: a hit target is a claim. So v5.md §3.4's own
    example needs `:claim()`, and then a validator or check (C4).
  - With those two markers, 0 warnings.
- **A demo set** gives 7 warnings.
  - Fields that should be claims: `collect.coins` (`t.int(0, 1e6)`), `hit.damage` (`t.f32`), `hit.origin` (131,073
    codes per axis), `hit.part` (`t.instance`).
  - Fields that are inputs: `settings.volume` (`t.number(0, 1, 1e-5)`, 100,001 codes), `settings.name`, and
    `confirm reply.note`.
  - Correctly silent: `move.stick` (255 codes), `move.look` (`t.angle`).

**What it catches.** Outcome and world claims written in free-form shapes: amounts, damage, positions, instance
targets, large ids, free text carrying structure. It moves the question "how would an exploiter abuse this?" onto
the field's line (AC §3.2). It costs nothing at run time: it only adds friction for the developer.

**What it misses** (false negatives, all in `lint_freeform.out`'s demo set):
- outcomes in input-shaped codecs: `finish.won` (`t.bool`), `finish.place` (`t.int(1, 12)`), `collect.coin`
  (`t.int(1, 500)`);
- a completion time `t.number(0, 600, 0.01)`, which has 60,001 codes and so falls under the threshold;
- small ids, and choices among a server-provided set (a claim of eligibility).

The rule is syntax, not meaning: the compiler can't recognise outcomes (AC §3.2).

**False positives:**
- chat and other free text;
- names and search strings;
- fine settings sliders;
- cosmetic camera or UI coordinates.

Each takes one `:input()`. The 2^16 threshold puts every v5.md §3.4 input and these demo inputs (255-code sticks,
enums, slot indices) below it, and ids, currency up to 10^6 and fine positions above it. Moving it changes only
which fields need a marker, so it is a constant, not an option ("none is a knob", v5.md §4.9).

| Option (`lync.toml`) | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `[check] freeFormField` | `"warn" \| "error" \| "off"` | — | — | `"warn"` | build time only: one codec-tree walk per client-sent payload; 0 B and 0 ns at run time; one marker per flagged field |

### C6. Cost probe: the fix and the results

**The fix** (`checks_cost.luau`). The atom-copy line ran `NA = N // 10` copies but `bench` divided by `N`, so it
printed a tenth of the cost. `bench` now takes the count it divides by.
- The old `.out` printed 9.8 ns interpreted and 6.4 ns native.
- The real figure is 87–90 ns interpreted and 55–61 ns native per 180 B atom. That agrees with ×10 of the old
  line.

Two more fixes were made while extending the probe, both affecting only the new runner lines. Each run now starts
from empty state, and the clock keeps rising across runs: a restart at 0 made the token bucket refill negatively
and sent `monotonic` down its late-frame branch. The probe asserts that only the failing case fails (14,000,000 of
14,000,000 counted).

**Results** (verified, `checks_cost.out`; ns per message, the range over 3 process runs, each the best of 7).
"Net" subtracts the same run's no-checks baseline (loop, payload fetch, nil test).

| Line | Interpreted | Native |
|---|---|---|
| raw `within` (distance² ≤ max², buffer state) | 53–61 | 7.4–8.3 |
| raw `monotonic` (strict >) | 16–18 | 3.3–5.9 |
| raw `maxTotal`, 16 buckets | 74–78 | 14–21 |
| aim ring write (telemetry) | 51–53 | 7.5–13.4 |
| atom copy, 45 samples, 180 B (telemetry; fixed) | 87–90 | 55–61 |
| runner baseline, definition with no checks | 46–50 | 22 |
| `within`, vector field, reference function, net | 101–109 | 50–56 |
| `within`, number field, net | 108–116 | 47–49 |
| `monotonic` with the frame key, net | 175–183 | 57–63 |
| `maxTotal`, sliding 16 buckets, net | 240–248 | 74–84 |
| `maxTotal`, token bucket, net | 195–241 | 65–66 |
| `within` + `monotonic` + `maxTotal` on one message, net | 508–541 | 176–183 |
| `within` failing every message, `drop`, net (fact record excluded) | 105–107 | 49–53 |
| clamp of a vector to the sphere | 56–58 | 53–63 |

**Reading.**
- **Dispatch, not arithmetic, is the cost.** The raw kernels are 3–21 ns native; through the table-driven runner
  each check costs 47–84 ns native. The rest is reading the check descriptor, looking up the payload field by
  string key, the reference call, and a call per check.
  - The checks are declared at run time on the server view, so neither path generates them.
  - Building one specialised closure per check at declaration would remove part of the dispatch (not measured).
  - The research's "27–49 ns native" for three checks (AC §4.2) measured kernels without dispatch.
- **At scale** (derived): 100 players × 60 messages/s, each with all three checks, is 1.06–1.10 ms/s native (about
  0.11% of one core) and 3.0–3.2 ms/s interpreted.
  - Add per message +18–38 ns for the `xpcall` when the definition has references but no validator (DIAG §9).
  - Add +20.5 ns native per failure for the fact record (DIAG §5.2).
- **The clamp line shows no native speed-up.** That points to its vector arithmetic not being lowered by this
  build's codegen. It was not investigated further. It runs only on failures under `clamp`.
- **Memory** (derived): 100 players × 10 `maxTotal` checks is 144 KB. A `monotonic` check is 16 B per player, and
  `within` is 0 B.
- **Not measured:** Roblox's server build, `vector` against a real `Vector3` (the same native type in Roblox, per
  the skill's references), and the state lookup by `Player` rather than a slot index.

### C7. Implications (checks and U12)

1. Declare the three checks on the server view as `Net.<def>:<check>(path, options)`. References are server
   functions, and bounds and retunes stay off the client and out of the hash (C0).
2. Keep `:claim()` and `:input()` as codec methods in the shared schema, and hash them as codec type 26, so the
   planner and the lint see them with no exception to the hash rule (C4).
3. Make `policy` required and add `"deliver"` beside `drop` and `clamp`. Lync then never picks a consequence, and
   games can tune tolerances from facts first (C0, R25).
4. Run checks after `limit` and before validators, with references inside the validator's `xpcall`. Commit
   `monotonic` and `maxTotal` state only for delivered messages (C0).
5. Ship one fact, `constraint`, with the flat evidence `check`, `kind`, `policy`, `observed`, `bound`, `late`,
   following `unresolved`'s pattern (C0).
6. Order `monotonic` by the frame key (tag count, or unreliable seq) and accept late frames that are ≤ the stored
   value. Without it, 1.3% of unmodified unreliable traffic fails on the default network (C2,
   `monotonic_reorder.out`).
7. Build `maxTotal` as a 16-bucket sliding window. It bounds any 15/16 window to exactly `cap`, where a token
   bucket allows 1.94 × `cap`, for 128 B more state (C3, `maxtotal_bounds.out`).
8. Let a check on a claim leaf satisfy the claim's verification, as `validate` does, and drop unverified claim
   messages with the native fault `claimUnverified` (C4).
9. Add `resetChecks(player)` so games can reset counters at rounds and respawns without an `exempt` window (C0,
   C2).
10. Adopt `freeFormField` as a build-only warning with the exact 2^16 rule. It flags the real claim in v5.md §3.4
    (`strike.target`) and one chat false positive, and misses input-shaped outcomes by design (C5).
11. Update v5.md §3.4's example: `strike.target` gets `:claim()` plus a validator or check, and `chat` gets
    `:input()` (C5).
12. State the checks' cost as 47–84 ns native per check (176–183 ns for three), and note that dispatch dominates.
    A per-check closure built at declaration is the measured-later way to cut it (C6).
13. Register the new codes: `constraint` (fact); `claimUnverified` (fault); `rolePlacement` (declaration);
    `checkKind`, `checkOption`, `checkPool` (caller); `freeFormField` (build). Register the counters
    `checksSkipped` and `claimsUnverified` (C0, C4, C5).
