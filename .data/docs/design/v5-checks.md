# Lync v5: checks, claims, telemetry and sealed delivery

Draft 3.6, 2026-10-15. Part of the v5 design (`v5.md`); changes from draft 3.5 are in `v5-3.6-changes-checks.md`.
This file specifies, completely:
- **checks** (§1–§5): `within`, `monotonic`, `maxTotal` and `derive`, declared on the server view;
- **claims** (§6): the `:claim()` and `:input()` codec markers, the claim requirement and the `freeFormField` lint;
- **telemetry** (§7): `:aim`, `:series`, `:atom`, delivery to game code, and what Lync's docs must say about
  Roblox's terms;
- **sealed delivery** (§8): server-sent values sent before they become visible and revealed by a key.

They were the `checks` and `telemetry` extensions of `v5-extensions.md` and R34's form (a); they are now part of
the core. The markers and their hash (§6.1) are built in milestone 1, the claim requirement with validators in
milestone 2, the lint in milestone 3, and the rest in milestone 7 (`v5.md` §10). Codes, counters and options this
file adds are listed in §9; pending measurements in §10.

Every part follows `v5.md` §0: Lync reports facts with exact triggers and numeric evidence, and never rewrites a
value a client sent. A message is dropped only for a rule the developer declared: a `validate` returning `false`, a
check with `policy = "drop"`, a claim with no verifier (§6.3), as `limit` and traps already do (`v5.md` §6.1).
Nothing here scores, ranks, delays or throttles a player.

## 1. Checks: the common frame

### 1.1 Decision: where checks are declared

- **Problem.** A check compares a client value with server truth, so it needs server functions and server-only
  bounds. The shared schema is evaluated on the client, can't hold functions, and is readable by a modified client.
- **Options:** (a) codec methods in the shared schema (`t.int(0, 1000):maxTotal(5000, 600)`); (b) **calls on the
  server view**, as `:trap()`, `:refers()` and `:canary()` are (`v5-integrity.md` §3, §8, §9).
- **Choice: (b)** `[checks-telemetry C0]`. References are server functions. Bounds stay off the client, since the
  server shard is never replicated (`v5.md` §3.5), so a modified client can't read a tolerance and use exactly all of
  it. Checks change no bytes, so they stay out of the schema hash (`v5.md` §4.7) and a retune needs no client
  rebuild. `:claim()` stays in the shared schema (§6.1), because the planner and the lint must see it.

### 1.2 Shape and scope

`Net.<definition>:<check>(path, options)`, with `<check>` one of `within`, `monotonic`, `maxTotal`, `derive`.
- **`path`** names a field of `data`, with dots through records and optionals (`"origin"`, `"hit.origin"`); `""`
  names `data` itself when it isn't a record. Paths can't enter arrays, maps or union variants. A path that names no
  field throws `unknownField`; a field whose codec the check doesn't take throws `fieldKind`.
- **Types.** The generated server shard types `path` as a union of the literal paths each check accepts, and the
  options per path (§5.4 gives `derive`'s overloads); on the runtime path `path` is a string checked at the call.
  Whether the old solver picks an overload from a literal argument without an annotation is milestone 3's typing
  proof (§10).
- **Scope.** `data` of client-sent events and of client requests' asks. Replies to server `invoke`s are not
  covered: answers have no validator step, and the code that called `invoke` checks its result. A check declared on
  a server-sent definition or a collection throws `viewPlacement`.
- **An absent optional.** A check whose path passes through an optional that is absent in a message is not
  evaluated for that message and changes no state.
- **When.** A check may be declared at any time; it applies to messages decoded after the call. There is no call
  that removes one. Its **index** is its 1-based position among the definition's checks in declaration order.
- **Pending.** `research/refusals-rejudged-4.md` re-judges R35 (`maxRate`, `planar`, `exempt`, `cooldown`). Until it
  lands, they stand as in draft 3.5: `cooldown` is folded into `limit`, `exempt` is not adopted (`resetChecks`, §1.6,
  resets state without an exemption window), and `maxRate` and `planar` are not adopted.

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

`v5.md` §6.1 changes as follows (the runtime unit edits that section; the exact text is in this file's change
record):
- **Step 5** is unchanged: control; traps and reachability; answers; `unresolved`; `limit`; the report-only checks
  of milestone 5. Messages over `limit` therefore never touch check state.
- **Step 6, claims, checks and validator**, per message of a definition, in this order:
  1. **Claim requirement.** If the definition has an unverified claim leaf (§6.3), the message is dropped (an ask is
     answered `rejected`), counted in `claimsUnverified` and reported as `claimUnverified`. Nothing below runs.
  2. **Evaluate** every check of the definition in declaration order, each on the decoded values. Each failure
     records one `constraint` occurrence. A game function a check calls (`within`'s `reference`, `derive`'s `fn`)
     runs under the validator rules (§1.7).
  3. If any failing check has `"drop"`, the message is dropped (an ask is answered `rejected`); the validator is not
     called and nothing is committed.
  4. **Validate**, as today: `false`, a throw or a yield drops the message.
  5. **Commit**, for a message that will be delivered: `monotonic` stores, `maxTotal` charges. A failing check with
     `"deliver"` commits too, so check state always describes what game code received.
  Messages of one frame are handled in order, each committing before the next is evaluated.
- **Step 6b, sample** (§7.3), then **step 7, delivery**.

Checks run before the validator, so a validator sees only messages that passed every `"drop"` check. Report-only
checks of milestone 5 stay in step 5, so they see messages a check or a validator later drops, as they already see
messages a validator drops.

### 1.5 The fact `constraint`

One reason with `kind` 1–4: `v5.md` §7.3's rule is one reason, or one evidence value, per trigger whose cause or
knob differs (draft 3.5 root cause C), and `kind` is that value, with known causes listed per kind in §2–§5. One
reason keeps evidence narrowing on `reason` alone, the form proven on both solvers `[probes review-2 t3]`, as
`unresolved`'s `what` does.

| Reason | Exact trigger | Action | Evidence | Known causes on an unmodified client |
|---|---|---|---|---|
| `constraint` | a check declared on the message's definition fails, by its kind's trigger: §2.2 (`kind` 1), §3.2 (2), §4.2 (3), §5.2 (4) | `"drop"`: dropped, ask `rejected`; `"deliver"`: delivered | `check` (the 1-based index, §1.2), `kind` (1 `within`, 2 `monotonic`, 3 `maxTotal`, 4 `derive`), `policy` (1 drop, 2 deliver), `observed`, `bound` (per kind, below), `late` (1 when the message's frame key is older than the stored key; only `monotonic` stores a key, so it is 0 for kinds 1, 3 and 4) | per kind: §2.4, §3.4, §4.4, §5.3 |

| `kind` | `observed` | `bound` |
|---|---|---|
| 1 `within` | the distance d, in the field's unit | the maximum distance applied to this message |
| 2 `monotonic` | the value | the stored value |
| 3 `maxTotal` | the window sum S plus the amount | `cap` |
| 4 `derive` | the distance d after snapping (1 for an unequal `t.enum` or `t.bool`) | `tolerance` |

- Evidence is numbers from the decoded value and the server's own value, never client bytes.
- The fact's key is (player, reason, namespace, definition) (`v5.md` §7.3), so failures of two checks of one
  definition coalesce in one window, whose closing fact carries the last occurrence's `check`; `count` counts both.
- Recording costs 20.5 ns native per occurrence `[diagnostics §9]`.

### 1.6 State and `resetChecks`

- **State** is kept per (player, check), or per (player, pool) for a `maxTotal` pool. It is allocated at the
  player's first message that reaches the check and freed when the player leaves.
- **`Net.<definition>:resetChecks(player)`** clears that player's state for every check declared on the definition,
  including the windows of the pools its `maxTotal` checks belong to. It is the call for rounds and respawns that
  legitimately restart a counter; it opens no exemption window. Cost: one table clear per check.

### 1.7 Game functions inside checks

- A `reference` or `fn` call runs in its own `xpcall`, with the validator's rules (`v5.md` §6.1 step 6): a throw is
  reported natively as `validatorError`, a yield as `validatorYielded`, spaced per (code, definition) per
  `observe.window`; the message names the function (`arena.strike:within origin reference`). The message is dropped
  (an ask is answered `rejected`), checks after it are not evaluated, and occurrences already recorded stand. A
  return of the wrong type is raised inside that call, so it is a throw.
- A function returning nil skips its check for that message, counted in `checksSkipped`; nothing is committed for
  that check.
- **Cost:** +18–38 ns per protected call `[diagnostics §9]`, once per game function and once for the validator.
- **`perceived()`.** Whether a `reference` or `fn` may call `perceived(player)` is `v5-collections.md`'s rule; checks
  run during the dispatch of the message's frame, as validators do. (Awaiting the collections unit's decision; see
  the change record.)

## 2. `within`

### 2.1 Semantics

`Net.strike:within("origin", { reference = rootOf, maxDistance = 6, policy = "drop" })` `[checks-telemetry C1]`.
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
   delay adds an unmeasured amount (§10). A reference that reads `rewind` at the client's perceived tick
   (`v5-collections.md`) removes the latency term for records Lync replicates.
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
| `path` | string | — | a field of a codec in §2.1, through records and optionals | required | none |
| `reference` | `(Player, Data) -> (R?, number?)`; R is `number` for scalars and `t.angle`, `Vector3` for vectors and `t.direction` | — | — | required | the game's own, once per message, in its own `xpcall` (§1.7) |
| `maxDistance` | number (real) | the field's unit: studs, radians for `t.angle` and `t.direction`, the integer's unit | ≥ 0, finite | required | none |
| `policy` | `"drop" \| "deliver"` | — | — | required | none |

Measured, net of the runner's per-message baseline `[checks-telemetry C6]`: 50–56 ns native and 101–109 ns
interpreted per message for a vector field, 47–49 and 108–116 ns for a number field; a failure adds 20.5 ns native.
State 0 B; wire 0 B.

## 3. `monotonic`

### 3.1 Semantics

`Net.input:monotonic("seq", { order = "increasing", policy = "drop" })` `[checks-telemetry C2]`: a number that
unmodified client code never decreases in send order (`"nondecreasing"`) or always raises (`"increasing"`).
- **Frame key.** On the reliable lane, the frame's tag count (`v5.md` §4.5); on the unreliable lane, its extended
  upstream seq (§4.4). Messages of one definition in one frame are in call order (§4.1), so they share a key and are
  compared in order.
- **State:** the stored key s* and value v*, two f64 per (player, check).
- Codecs: `t.int(min, max)`, `t.int()`, `t.number`, `t.f32`, `t.f64`. `t.angle` wraps, so it is `fieldKind`, as is
  every other codec.

### 3.2 Exact trigger

For a value v in a frame with key s:
- no stored value: never fails;
- s ≥ s*: fails when v < v* (`"nondecreasing"`) or v ≤ v* (`"increasing"`); `late` = 0;
- s < s* (a late frame, possible only on the unreliable lane): fails when v > v* (`"nondecreasing"`) or v ≥ v*
  (`"increasing"`), since a value sent earlier can't exceed one sent later; `late` = 1.

**Commit** (§1.4): for s ≥ s*, (s*, v*) ← (s, v); a late frame stores nothing.

**Why the key** (`checks-telemetry/monotonic_reorder.out`): on `v5.md` §9's default network, 1.31–1.33% of
delivered unreliable frames arrive after a newer one, none 64 or more behind. A rule against the last accepted value
fails on each of them, 23.6% of frames at 0.05 s jitter; the keyed rule fails on none, as §9 requires.

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
   (unverified on Roblox devices); whether `GetServerTimeNow()` can decrease on a client is unmeasured (§10).

Not causes: loss (gaps pass), reordering (the key), duplicates (the replay window drops them).

### 3.5 Options and cost

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `path` | string | — | a field of a codec in §3.1, through records and optionals | required | none |
| `order` | `"nondecreasing" \| "increasing"` | — | — | `"nondecreasing"` (derived: the weaker rule, which raises no fact on equal values) | none |
| `policy` | `"drop" \| "deliver"` | — | — | required | none |

Measured, net: 57–63 ns native and 175–183 ns interpreted per message `[checks-telemetry C6]`. State 16 B per player
per check; wire 0 B.

## 4. `maxTotal`

### 4.1 Semantics and the window

`Net.collect:maxTotal("coins", { cap = 5000, seconds = 600, policy = "drop" })` `[checks-telemetry C3]` bounds the
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

**Guarantee** (derived, and measured above): any span of 15/16 × `seconds` or less holds at most `cap` of committed
amounts while every failing message is dropped; any span of `seconds`, at most 2 × `cap`; the long-run rate is at
most `cap`/`seconds`. Under `"deliver"`, failing amounts are committed too (§1.4), so S is the sum game code
received and `observed` reports how far it went past `cap`.

- **Codecs:** `t.int(min, max)` and `t.number(min, max, step)` with min ≥ 0. `t.int()`, `t.f32`, `t.f64` and any
  codec with negative values are `fieldKind`: a negative amount would refund the window.
- **`pool`:** checks with the same pool name, on any definitions of the namespace, share one window per player
  (coins from `collect`, `sell` and `quest`). They must declare equal `cap` and `seconds`, else `checkPool`.

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
| `path` | string | — | a field of a codec in §4.2, through records and optionals | required | none |
| `cap` | number (real) | the field's unit, per window | > 0, ≤ 2^53 | required | none |
| `seconds` | number (real) | s | 1–3600 | required | bucket width `seconds`/16 |
| `pool` | string or nil | — | 1–64 B | nil: the check's own window | one window per player per pool instead of per check |
| `policy` | `"drop" \| "deliver"` | — | — | required | none |

Measured, net: 74–84 ns native and 240–248 ns interpreted per message, including clearing up to 16 sums when a
message enters a new bucket `[checks-telemetry C6]`. State 144 B per player per check or pool; wire 0 B.

## 5. `derive`

### 5.1 Semantics

`Net.shot:derive("landing", { fn = landingOf, tolerance = 0.25, policy = "deliver" })` `[server-facts §U9.2]`: the
server re-computes an outcome the client sent from the inputs in the same message and compares.

```luau
-- server
local Projectile = require(ReplicatedStorage.Shared.Projectile) -- the module the client also calls
Net.shot:derive("landing", {
	fn = function(player, shot) return Projectile.landing(shot.origin, shot.velocity, shot.flight) end,
	tolerance = 0.25, -- studs
	policy = "deliver",
})
Net.craft:derive("result", {
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
  1. `fn(player, data)` returns r, or nil (§1.7).
  2. **Snap:** r goes through the field codec's own quantizer, the one the encoder applies (`v5.md` §3.3):
     `t.number` and each `t.vector3` component to its step, `t.angle` to its n, `t.direction` through the octahedral
     code, `t.f32` to the nearest f32. A value outside the codec's range is first limited to it (this is the
     server's value; the client's is untouched). `t.int`, `t.f64`, `t.enum` and `t.bool` are compared as returned.
  3. **Distance d:** §2.1's metric for the codecs there; 0 or 1 for `t.enum` (both forms) and `t.bool`.
- **Codecs:** §2.1's list, plus `t.enum` and `t.bool`. Records, arrays, maps, unions, `t.cframe` and `t.rotation`
  are `fieldKind`; a record outcome is one `derive` per leaf.
- `derive` keeps no state; commit stores nothing.

### 5.2 Exact trigger

The check is evaluated for a message when `oneIn` is 1, or when a draw `Random:NextInteger(1, oneIn)` returns 1 from
a `Random.new()` instance created without a seed at server start and used for nothing else (an unseeded `Random`
"uses a seed from an internal entropy source", documented, creator-docs `datatypes/Random.yaml`). The draw happens
after the frame arrived, so a client can't know before sending which of its messages are evaluated. An evaluated
check fails when not (d ≤ `tolerance`); equality passes, a NaN fails. A message not drawn is not evaluated and
passes.

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
   builds): unverified (§10). A tolerance of at least one grid step removes this cause while the gap stays under one
   step.
2. **A different algorithm:** per-frame integration on the client against a closed form in `fn`, after 1 s of flight
   at gravity 196.2 studs/s²: 3.27 studs off at 30 FPS, 1.64 at 60, 0.68 at 144, 0.41 at 240. Fix: one shared
   function.
3. **Inputs quantized after the client used them:** at 300 studs of flight, the 0.2369° of `t.direction(10)` is 1.24
   studs (derived). Fix: compute the outcome from the values as they will decode (`:round`, if the core-api unit
   adopts it; §10).
4. **Server state that differs from the client's,** when `fn` reads it: latency (§2.4 cause 1), parts not streamed
   in, moving geometry.
5. **Inputs that weren't sent:** the client's own clock, a random draw, local state. Fix: put them in the message
   (a seed, `Lync.tick()`) and check them with `within`.

**Tolerance.** In the field's unit, as `within`'s `maxDistance`. The smallest useful value on a quantized codec is
one grid step's distance: `step` for `t.number`, √3 · `step` for `t.vector3` (0.054 studs at 1/32), 2π/n for
`t.angle`, one octahedral cell for `t.direction` (0.47° at 10 bits, derived). The docs' formula: one step + the gap
between the client's algorithm and `fn` + lever arm × input quantization error + speed × latency when `fn` reads
moving server state.

### 5.4 Options, types and cost

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `path` | string | — | a field of a codec in §5.1, through records and optionals | required | none |
| `fn` | `(Player, Data) -> T?`, T the field's decoded type | — | — | required | the game's own, per evaluated message, in its own `xpcall` (§1.7) |
| `tolerance` | number (real) | the field's unit | 0–2^31, finite; only 0 for `t.enum` and `t.bool` | required | none |
| `policy` | `"drop" \| "deliver"` | — | — | required | none |
| `oneIn` | integer | messages per evaluation | 1–1000 | 1 (derived: principle 1, every message is checked unless the developer trades that for `fn`'s cost) | above 1: one draw per message, 24–32 ns in the CLI (`v5-integrity.md` §4's figure; `Random:NextInteger` on Roblox servers unmeasured, §10) and `fn` on 1/`oneIn` of messages on average; a message not drawn passes unchecked, under `"drop"` too |

- **Types.** Generated shard (both solvers): `derive` is an intersection of one overload per accepted path, each
  with its own `fn` return type: `((self, path: "landing", options: DeriveOptions<ShotData, Vector3>) -> ()) &
  ((self, path: "flight", options: DeriveOptions<ShotData, number>) -> ())`, with `DeriveOptions<D, T> = { fn:
  (Player, D) -> T?, tolerance: number, policy: "drop" | "deliver", oneIn: number? }`. Runtime path: a type
  function from the literal path to the field type under the new solver; `unknown` under the old. roblox-ts: one
  overload per path, `this: void`.
- **Measured** (`server-facts/server_facts_cost.out`): Lync's share for a vector field is 6–12 ns native and
  32–36 ns interpreted per message; with an exact compare (`t.enum`) the whole runner is 7.2–8.5 ns native. Add the
  protected call (§1.7) and 20.5 ns per failure. State 0 B; wire 0 B.

## 6. Claims

### 6.1 The markers `:claim()` and `:input()`

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
- **`:input()`** has one effect: it silences `freeFormField` on a free-form leaf (§6.4). Draft 3.5 dropped it (M4:
  unmarked fields are inputs already); it returns because the lint needs a way, on the field's own line, to record
  that a free-form leaf was looked at and is an input, and an unmarked leaf can't say that.

| Marker | Placement | Default | Cost |
|---|---|---|---|
| `:claim()` | any codec in a client-sent payload | unmarked leaves are inputs | 0 B wire; 2 B hash input; one flag test per message; a verifier per claim leaf of `data` (§6.2) |
| `:input()` | as `:claim()` | — | 0 B wire; 2 B hash input; no run-time effect |

### 6.2 Decision: what verifies a claim

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
  of any kind and any policy has a path naming that leaf. A `"deliver"` check counts: its failures are reported, and
  the policy is the developer's. Leaves inside arrays, maps and union variants, and leaves of codecs no check takes
  (strings, instances), are verified only by a validator.
- **The flag.** Lync keeps one flag per definition, "has an unverified claim leaf", set at definition time from the
  schema and recomputed at each `validate` or check declaration. Per message it costs one boolean test.
- **Replies** of server requests may carry markers, for the lint only; answers have no validator step.

### 6.3 Decision: a message with an unverified claim

- **Problem.** A message arrives for a definition whose claim leaves the server hasn't verified. Its cause is the
  server's declarations, not what the player sent. The hard window is the time between a server script's first use
  of the namespace and its `validate` or check calls, when messages can already arrive.
- **Options:** (a) **drop it, count it, and report a fault**; (b) deliver it and report the fault; (c) hold it until
  a verifier is declared.
- **Choice: (a).** `:claim()` is the developer's declaration that the leaf reaches game code only after a server
  verification; (b) would deliver exactly what the marker excludes, and (c) holds client data for an unbounded
  time. The drop executes the developer's declaration, as `limit` does.
- **Exact trigger and action.** A message of a definition whose flag (§6.2) is set, at step 6 (§1.4) before checks
  and validators: dropped, an ask answered `rejected`, counted in `claimsUnverified`, and reported natively as
  **`claimUnverified`** (family `fault`), at most once per definition per `observe.window` (`v5.md` §7.2):
  `[Lync] claimUnverified: arena.strike data.target must have a validator or a check, got none`. It carries no fix,
  since there are two (`v5.md` §7.1).
- **Known causes:** none on the client side. On the server, game code that declares no verifier, or declares it
  after the definition's first messages arrive (a script that yields between requiring the shard and declaring).
  The docs say: declare checks and validators before the script's first yield.
- **What it guarantees:** no message holding a claim reaches `connect` or `handle` without a game validator or a
  declared check having run on it. It is defeated by a validator that returns `true` unconditionally, and by marking
  a claim `:input()` to silence the lint.

```luau
-- shared schema
strike = Lync.event({ from = "client", lane = "unreliable", data = {
	target = t.int(1, 2 ^ 40):claim(), origin = t.vector3(-2048, 2048, 1 / 32):claim(), aim = t.direction(11),
} }),
-- server
Net.strike:within("origin", { reference = rootOf, maxDistance = 6, policy = "drop" })
Net.strike:refers("target", "fighters") -- v5-integrity.md §8
Net.strike:validate(function(player, s) return Fighters.alive(s.target) end)
```

### 6.4 The `freeFormField` lint

The rule, its evidence, severity option and channel are the `freeFormField` row of `v5-tooling.md` §3.4: a free-form
leaf (unbounded floats and integers, more than 65,536 codes per component, strings, buffers, instances, custom
codecs) in a client-sent payload with no role marker on itself or an enclosing codec. Its relation to this file:
- **It is what makes the marker protect.** A flagged leaf gets `:claim()`, and then §6.2 requires a server
  verifier; or it gets `:input()`, which records the decision on the field's line.
- **Measured on stand-in codecs** (`checks-telemetry/lint_freeform.out`): `v5.md` §3.4's `arena` gives 2 warnings,
  `chat data` (an input: `:input()`) and `strike data.target` (a claim: `:claim()` and a verifier), and 0 with those
  markers. A demo set gives 7: four claims (`collect.coins`, `hit.damage`, `hit.origin`, `hit.part`) and three inputs
  (`settings.volume`, `settings.name`, `confirm reply.note`).
- **What it misses, by design:** outcomes in input-shaped codecs (`t.bool` wins, `t.int(1, 12)` placings,
  `t.int(1, 500)` amounts), a `t.number(0, 600, 0.01)` completion time (60,001 codes), small ids, and choices among
  a server-provided set. The rule is syntax; it can't recognise outcomes `[anticheat-design §3.2]`.
- **Threshold** 65,536 codes: a constant, chosen, not measured. Below it are every input of `v5.md` §3.4 and the
  demo inputs (255-code sticks, enums, slot indices); above it, ids, currency up to 10^6 and fine positions. A
  measured count of false positives and misses per threshold over real schemas would change it. Moving it changes
  only which fields need a marker, so it is not an option.
- On the runtime path the planner computes it and drops it: there is no build to report to, and a line in every
  session is the channel M11 refused.

## 7. Telemetry

Telemetry keeps per-player copies of values the game already sends, and hands them to game code. It raises no fact
and computes nothing about them.

### 7.1 Decision: where telemetry is declared

- **Options:** (a) codec methods in the shared schema (`t.direction(11):aim()`) `[anticheat-design §5.2]`;
  (b) **calls on the server view**, as checks (§1.1).
- **Choice: (b)** `[checks-telemetry T1]`. Sampling changes no bytes, so it stays out of the hash and a retune needs
  no client rebuild; the server shard is never replicated, so a modified client can't read which fields are sampled;
  nothing the client must see depends on it.
- **Scope** as checks (§1.2): `data` of client-sent events and client requests' asks, on the server; elsewhere
  `viewPlacement`. Paths as §1.2 (`unknownField`, `fieldKind`). Declared at any time; applies to frames decoded
  after the call.

### 7.2 Streams and their entries

Each declaration keeps one ring per player of `ring` entries; one ring per definition, so a definition names its
ring (a second `:aim` or `:series` on a definition throws `telemetryTwice`).
- **Timing** (`Net.<def>:series()`): one entry per frame carrying a delivered message of the definition.
- **Values** (`Net.<def>:series(path)`): the same, plus the field's value. Scalars (`t.int`, `t.number`, `t.f32`,
  `t.f64`, `t.angle`, `t.bool` as 0 or 1, a list enum's 0-based index, a Roblox enum item's `Value`) are stored as
  the nearest f32, so integers above 2^24 lose precision; vectors (`t.vector3`, `t.vector3f32`, `t.direction`) as three
  f32. Lync stores values; differences are the analyst's.
- **Aim** (`Net.<def>:aim(path)`): the field's look direction as yaw and pitch. Each aim codec gives a unit
  direction (x, y, z): `t.direction` itself; `t.rotation` and `t.cframe` their `LookVector`; a record
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
65.536 s wrap, its times alias, and the window search (§7.4) is no longer sorted. u32 fields are exact for every ring
(`ms` wraps after 49.7 days, `key` after 138 days at 360 frames/s), for 4 B more per entry.

**Decision: one entry per frame.** A frame's messages share one arrival time, so Lync samples the last delivered
message of the definition in each frame (messages are in call order, `v5.md` §4.1): more entries would add values
with no time between them, and one per frame bounds a ring's turnover by the inbound frame budget (at most 120 + 240
frames/s at the defaults, `v5.md` §7.5). At 60 frames/s a 64-entry ring holds 1.07 s.

### 7.3 Where it runs

**Step 6b, sample** (§1.4), after the checks' commit and before delivery, on messages that will be delivered, with
the values game code receives. Dropped messages are not sampled: each drop is already a fact or a counter
(`overLimit`, `constraint`, `validatorRejections`), and sampling them would make a second record of one event. It runs
in the pipeline loop, not in a handler thread, so a yielding handler can't delay it. `ms` and `key` are read once per
frame.

### 7.4 Atoms

`Net.<def>:atom({ before, after, fields, series, pending })`: a fixed record taken when a message of the definition
is delivered, with a window of another definition's stream around it. One atom declaration per definition (a second
throws `telemetryTwice`).
1. **Trigger** (step 6b). When at least one `Lync.telemetry.atoms` connection exists and the player has a free pending
   slot, Lync copies the header and the `fields` values (as f64, a vector as x, y, z) into the slot, due at
   `os.clock()` + `after`. With no free slot it takes nothing and counts `atomsSkipped`; it never evicts. With no
   connection it takes nothing.
2. **Complete**, once per flush, where fact windows are swept (`v5.md` §7.3). For each due atom, Lync binary-searches
   the `series` ring for the first entry whose `ms` is no older than the trigger's `ms` − 1000 × `before` (u32
   differences, exact by §7.2), and copies it and every newer entry into the player's batch buffer.
3. **Hand off** (§7.5).

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

### 7.5 Decision: how samples reach game code

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

### 7.6 API and types

```luau
-- server
Net.look:aim("dir")                                   -- look: from = "client", data = { dir = t.direction(11) }
Net.strike:series()                                   -- timing only
Net.strike:atom({ before = 0.5, after = 0.25, fields = { "origin", "target" }, series = Net.look })
local connection = Lync.telemetry.atoms(function(batch: Lync.AtomBatch)
	Export.queue(batch.player, batch.definition, batch.data) -- game code (§7.8)
end)
local look = Lync.telemetry.read(player, Net.look)    -- a copy of the ring, or nil
```

Types are plain records with no `read` modifiers, since the old solver rejects them in generated shards (`v5.md`
§3.2); the tables are frozen at run time (the layout and its `fields` too). The generated server shard types each
call's `path` and `fields` as unions of the literal paths it accepts; the runtime path checks strings at the call.

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
	aim(this: void, path: AimPath<T>, options?: { ring?: number }): void;
	series(this: void, path?: SeriesPath<T>, options?: { ring?: number }): void;
	atom(this: void, options: { before?: number; after?: number; fields?: ReadonlyArray<NumericPath<T>>;
		series?: ServerEvent<unknown>; pending?: number }): void;
}
declare namespace telemetry {
	function atoms(this: void, fn: (batch: AtomBatch) => void): Connection;
	function read(this: void, player: Player, def: ServerEvent<unknown>): Stream | undefined;
	function decode(this: void, batch: AtomBatch): ReadonlyArray<Atom>;
}
```

`AimPath<T>`, `SeriesPath<T>` and `NumericPath<T>` are emitted per definition as literal unions, never computed by
type-level recursion. Caller errors: `unknownField`, `fieldKind` (the codec isn't one the call takes),
`telemetryTwice`, `seriesMissing` (`series =` a definition with neither `:aim` nor `:series`), `viewPlacement`, and
the option codes of §9.

### 7.7 What Lync does not do

Each follows "Lync reports facts" (R23) and "no automatic consequence" (R22, R24):
- **No statistics, scores, thresholds or models.** The research's online mean and variance
  `[anticheat-design §5.2]` are dropped: a summary Lync chooses is the first step of a verdict, and raw samples cost
  as little to keep. Means, deltas, angular speed, reaction times and models belong to game code or offline tools.
- **No fact from a telemetry value**, and no flag meaning anything but its exact condition (§7.4).
- **No consequence.** Sampling never changes what is delivered, and nothing in telemetry drops, delays, throttles or
  tags a player.
- **No export, storage or transport.** Lync makes no HTTP request, writes no DataStore and holds no secret, as
  diagnostics export is a recipe `[diagnostics §5.4]`. Game code owns the 500 HTTP requests/min per server, the
  "Allow HTTP Requests" setting (documented, creator-docs `cloud-services/http-service.md`) and the legal obligations
  (§7.10).
- **No user ids and no client text in the data.** A batch carries the `Player`; the buffer carries no id. Atoms and
  series take numeric codecs only, so a batch can't carry chat or any other text a player typed.

### 7.8 The export recipe (docs)

One `Lync.telemetry.atoms` connection appends each batch to a buffer behind a header the recipe fixes (version u8,
namespace and definition as u16-length strings, the exported player key as f64, count u16), and sends the buffer every
2 s with one `HttpService:RequestAsync` whose `Body` is `buffer.tostring(…)` (a body "can be any string, including
binary data", documented, `HttpService.yaml`), retrying with backoff (documented best practice).
- At 100 players × 2 atoms/s × 591 B, that is 118 KB/s: 30 requests/min of 236 KB each (derived).
- A request body limit is not documented (`HttpService.yaml` and `http-service.md` searched for "size", "limit",
  "MB", "body"): unverified (§10). The recipe takes a byte limit as a parameter and splits the buffer at it.
- `PostAsync`'s `compress` argument gzips the body (documented); `EncodingService`'s Zstd is the other route.

### 7.9 Known causes in the samples of an unmodified client

`checks-telemetry/telemetry_samples.out`, a model: v5.md §9's network, frame times drawn per case, not measured on
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
    nearly one time (magnitude unverified, §10).

**How it is defeated.** A modified client controls every value it sends and when; it can shape aim and timing like
any device. Telemetry raises the cost of crude automation and gives evidence for review; it proves nothing about one
player.

### 7.10 Options, memory and cost

| Option | Where | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|---|
| `path` | `:aim(path, …)` | string | — | a `t.direction`, `t.rotation`, `t.cframe` or `{ yaw = t.angle, pitch = t.angle }` field, through records and optionals | required | 65–73 ns native, 221–228 ns interpreted per sampled frame from a decoded direction; the record form adds four trigonometric calls (unmeasured) |
| `path` | `:series(path?, …)` | string or nil | — | a codec of §7.2's values, through records and optionals; nil: timing only | nil | timing: 22–24 ns native, 91–93 ns interpreted per sampled frame; values: unmeasured (§10) |
| `ring` | `:aim`, `:series` | integer | entries | 16–1024 | 64 (chosen: at least the 45 entries of the default window at 60 frames/s; atoms truncate above 85.3 frames/s) | E × `ring` per player: 768 B for aim at 64 |
| `before` | `:atom` | number (real) | s | 0–2 | 0.5 (the reported VACnet window `[anticheat-design §5.1]`) | needs `ring` ≥ (`before` + `after`) × the series' frames per second, else bit 1 |
| `after` | `:atom` | number (real) | s | 0–1 | 0.25 (VACnet, as `before`) | a pending slot held `after` s plus up to one server frame |
| `fields` | `:atom` | array of string | — | paths of §7.2's value codecs on the atom's definition, at most 16 values (a vector counts 3) | `{}` | 8 B per value per atom; trigger 35–38 ns native, 151–163 ns interpreted for 5 values |
| `series` | `:atom` | a definition with `:aim()` or `:series()` | — | — | nil: no entries | completion 252–260 ns native, 477–506 ns interpreted per atom of 46 entries |
| `pending` | `:atom` | integer | atoms per player | 1–64 | 8 (chosen: sustains 8/(`after` + 1/60 s) = 30 atoms/s per player at the default `after`; a definition firing faster needs more) | (19 + 8 · F) B each |
| `telemetry.batch` | `Lync.configure` | integer | atoms | 1–256 | 16 (chosen: the hand-off is 41–44 ns per atom amortised at 16; a larger batch holds more memory per player) | at most `batch` × the atom size held per (player, definition); 0.66–0.71 µs per hand-off plus 88–131 ns per connection |
| `telemetry.seconds` | `Lync.configure` | number (real) | s | 1–600 | 30 (chosen: equal to `observe.window`'s default, so an atom reaches game code no later than a coalesced fact) | an open batch is held up to this long |

- **Memory per player** (derived from the layouts): aim ring 768 B, timing ring 512 B, vector ring 1,280 B at 64;
  pending 8 × 51 B = 408 B for 4 values; batch buffer 16 × 591 B = 9.5 KB for 45-entry windows, at most
  16 × (51 + 64 × 12) = 13.1 KB. One aim series, one timing series and one atom declaration: at most 14.8 KB per
  player, 1.48 MB for 100 players. Allocated at the player's first sampled message, freed on leave.
- **Cost** (measured on the research's 4 B and 8 B layouts, `checks-telemetry/telemetry_cost.out`; the widened
  fields of §7.2 are the same number of buffer writes and copy 4 B more per entry, unmeasured): 100 players at 60 aim
  samples/s is 0.39–0.44 ms/s native and 1.3 ms/s interpreted; two atoms per player per second add 0.06 ms/s native
  and 0.13 ms/s interpreted, the batches about 0.01 ms/s. Wire 0 B: Lync samples traffic the game already sends (an
  aim stream needs the game to send its look direction, 22 bits per message for `t.direction(11)` plus framing).
- **Not sampled:** server-sent traffic, anything on the client, and `Player:GetCameraState()` (server-side camera
  under Server Authority, documented), which isn't traffic Lync decodes.

### 7.11 What Lync's docs must tell developers about Roblox's terms

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
  the users page links (§10).
