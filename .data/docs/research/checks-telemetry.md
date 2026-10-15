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
- [ ] C3. `maxTotal`
- [ ] C4. `:claim()` (and `:input()`)
- [ ] C5. U12: the free-form field lint
- [ ] C6. Cost probe: the fix and the results
- [ ] C7. Implications (checks and U12)

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
- number field: 47–49 ns native and 104–116 ns interpreted;
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

**Cost** (measured, C6, net): 57–63 ns native and 172–183 ns interpreted per message. The raw compare is 3.1–5.9 ns
native; the rest is the table-driven runner. State: 16 B per player per check. Wire: 0 B.
