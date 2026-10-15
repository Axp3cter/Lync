# Server facts: re-derivation, reaction timing, and later server-side facts

Researcher brief, 2026-10-15. Design research for Lync v5; no library code. Item numbers are from
`research/security-refusals.md` §4 (described in the research, never decided). This unit designs U9 and U10;
later units append U11, U14, U3 and U4.

**Read in full:** `design/v5.md` (§3.4, §4.1, §4.4, §5, §6, §7.3, §9), `design/v5-integrity.md`,
`research/anticheat-design.md` §3.2, §4.3, §7, §8, `research/interest-rewind.md` §11, `research/diagnostics.md`
§2, §5, §9, `research/v5-attempt.md` §5, `research/checks-telemetry.md` (C0 and C1 as written so far; C4 `:claim()`
is still unwritten there, so this file does not define it). Cited as `v5.md §n`, `INT §n` (`v5-integrity.md`),
`AC §n` (`anticheat-design.md`), `IR §n` (`interest-rewind.md`), `CT Cn` (`checks-telemetry.md`), `DIAG §n`.

**Labels:** **verified** (I ran it or read the source), **documented** (official docs), **reported** (third
party), **unverified**. Costs are **measured** (a probe here), **derived** (arithmetic from stated inputs) or
**asserted**.

**Tools.** Luau 0.742 built from `.data/projects/luau` (CMake Release, scratch build, not committed), interpreted
`-O2` and native `-O2 --codegen`, Intel Xeon 2.1 GHz with FMA3, 4 cores. Both facts run on the server, where
Roblox compiles natively only what is marked `--!native`, so both figures are given. CLI timings indicate scale;
Roblox's server build is not measured. Probes type-check clean (luau-analyze 0.740, new solver).

**Probes** (`.data/docs/probes/server-facts/`):
- `derive_determinism.luau` → `derive_determinism.out`: interpreted against native bit equality, f32 against f64,
  per-frame integration against the closed form.
- `server_facts_cost.luau` → `server_facts_cost.out`: per-message server cost of both items (2 process runs per
  mode, best of 7 per line).
- `reaction_sim.luau` → `reaction_sim.out`: the reaction estimate and each trigger on `v5.md` §9's default
  network model.

## Checklist

- [x] U9. `derive`: re-derivation of a claimed outcome
- [x] U10. `reactsTo`: response before stimulus, and the reaction floor
- [x] Implications (U9, U10)
- [ ] U11 (later unit)
- [ ] U14 (later unit)
- [ ] U3 (later unit)
- [ ] U4 (later unit)

---

## U9. `derive`: re-derivation of a claimed outcome

### U9.1 What it is, what it protects, what it doesn't

- **Mechanism.** A client sends an outcome it computed from inputs that travel in the same message (a
  projectile's landing point from its origin, velocity and flight time; a crafted item from its recipe). The
  server runs the same computation, `fn`, on the decoded message, snaps the result to the field's grid, and
  reports a fact when the claim is further from it than `tolerance` (AC §3.2, "Re-derivation instead of
  verification").
- **What it prices.** The link between inputs and outcome. A client whose simulation was changed (gravity, speed,
  spread or drop constants edited in memory) or whose outcome was edited after it was computed sends a claim the
  server's recomputation doesn't reproduce.
- **What it doesn't price.** The inputs. They are client-chosen, so a modified client that picks inputs and then
  computes the outcome with the shared function passes. Inputs need their own checks (`within`, `limit`, `rewind`).
  Every claim inside the tolerance passes as well.
- **Defeated by** (capability class): a modified client that computes its claims with the game's own shared
  function. `derive` makes forging cost a reimplementation of the game's function; it doesn't stop one.
- **The rule it sits under.** If the server can compute the outcome, the client needn't send it (AC §3.1). `derive`
  is for games that send it anyway: so the handler knows what the client saw, or so the server learns that the
  client's simulation diverged. The docs say the game should act on its own recomputation, never on the claim.

### U9.2 Decision: shape

- **Options.**
  - (a) The research's `:claim(Lync.derive(fn, tolerance))` in the shared schema (AC §3.2). Refused already: M8
    made `:claim()` a bare marker and moved verifiers out of the shared schema, because the client evaluates the
    schema and functions can't live there (`v5-changes.md` M8, R8).
  - (b) No new API: a docs recipe over `within`, `reference = function(p, d) return fn(p, d) end` (CT C1). It works
    today, but compares the unsnapped server value (up to half a step of extra error), doesn't take `t.enum` or
    `t.bool` (a crafted item, a hit flag), and reports `kind` 1, whose documented causes are latency (CT C1),
    not recomputation.
  - (c) **A fourth `checks` kind, `derive`**, declared on the server view like the others (CT C0):
    `Net.<definition>:derive(path, options)`.
- **Choice: (c).** It reuses all of C0: declaration, `path`, policies, the pipeline slot, the fact. It adds three
  things `within` lacks: snapping to the grid, exact codecs, and its own `kind`, so a fact says which known causes
  apply.

```luau
-- server
local Projectile = require(ReplicatedStorage.Shared.Projectile) -- the module the client also calls

Net.shot:derive("landing", {
	fn = function(player, shot)
		return Projectile.landing(shot.origin, shot.velocity, shot.flight)
	end,
	tolerance = 0.25, -- studs
	policy = "deliver",
})
Net.craft:derive("result", {
	fn = function(player, craft) return Recipes.result(craft.recipe, craft.inputs) end,
	tolerance = 0, -- exact: t.enum
	policy = "drop",
})
```

### U9.3 Where it runs

Step 5 of the inbound pipeline (`v5.md` §6.1), in CT C0's checks block: control; traps and reachability;
answers; `unresolved`; `limit`; **checks, `derive` among them, in declaration order**; then the report-only
checks of milestone 5. Then step 6, validators.
- `fn(player, data)` sees `data` after earlier checks' clamps (CT C0, evaluate). It runs inside the same `xpcall`
  as the validator, as `within`'s reference does: a throw is `validatorError`, a yield `validatorYielded`, and
  either drops the message (an ask is answered `rejected`).
- `derive` keeps no state, so C0's commit step has nothing to store.
- Inputs from server state (the shooter's rewound position, `Lync.tick()`) are read by `fn` itself. Whether
  `perceived(player)` may be called there is the `rewind` rule (IR §11.6 allows it only in the handler's
  synchronous part); CT C1 assumes the same for `within` references, so the two need one answer.

### U9.4 Comparison, exactly

1. `fn` returns r, or nil. Nil skips the check and counts `checksSkipped` (CT C0).
2. **Snap.** r goes through the field codec's own quantizer, the one the encoder applies (`v5.md` §3.3):
   `t.number` and each `t.vector3` component to its step, `t.angle` to its n, `t.direction` through the octahedral
   code, `t.f32` to the nearest f32. `t.int`, `t.f64`, `t.enum` and `t.bool` are compared as returned. A value
   outside the codec's range is clamped to it, as encode would refuse it, so the result stays comparable.
   Decoded claims are already on the grid, so both sides of the comparison are grid values.
3. **Distance d**, by codec: CT C1's metric (|v − r| for scalars and vectors, the wrapped difference for `t.angle`,
   the angle for `t.direction`); 0 or 1 for `t.enum` and `t.bool` (equal or not).
4. **Exact trigger:** not (d ≤ `tolerance`). Equality passes; a NaN from `fn` fails.
5. **Clamp** is CT C1's rule toward the snapped r. `t.direction`, `t.enum` and `t.bool` can't clamp
   (`checkKind`), as in C1.

Codecs taken: C1's list (`t.int`, `t.number`, `t.f32`, `t.f64`, `t.angle`, `t.vector3`, `t.vector3f32`,
`t.direction`) plus `t.enum` and `t.bool`. A record, array, map, union, `t.cframe` or `t.rotation` is `checkKind`.
A record outcome is declared as one `derive` per leaf.

### U9.5 Tolerance: unit and range

- **Unit:** the field's own unit, as `within`'s `maxDistance` (studs, radians, the integer's unit). One vocabulary
  for both checks; AC §3.2 asked for the same.
- **Range:** 0 to 2^31, finite. For `t.enum` and `t.bool` only 0 (`checkOption` otherwise).
- **Smallest useful value on quantized codecs: one grid step's distance.** A float difference smaller than one step
  can still land the two values on neighbouring codes when they straddle a rounding boundary, so tolerance 0 can
  report it; one step can't. Per codec: `step` for `t.number`, √3 · `step` for `t.vector3` (0.054 studs at 1/32),
  2π/n for `t.angle`, one octahedral cell for `t.direction` (about twice its maximum error, 0.47° at 10 bits,
  derived from `v5.md` §3.3's 0.2369°).
- **The docs' formula:** `tolerance` = one step + the gap between the client's algorithm and `fn` + lever arm ×
  input quantization error + speed × latency when `fn` reads moving server state. Each term is a known cause below.

### U9.6 Known causes on an unmodified client

Measured in `derive_determinism.out` unless marked.
1. **The same code gives different floats** (**verified** for one pair here):
   - Native against interpreted, same machine: `math.lerp` and `vector.lerp` differ bit-wise, in 57,506 of
     200,000 random lerps, by at most 2.27e-13. Native code lowers both to a fused multiply-add when the CPU has
     FMA3 (x64) or AdvSIMD (arm64) (`CodeGen/src/IrLoweringX64.cpp:790-822`, `:1347-1363`,
     `IrLoweringA64.cpp:866-877`); the interpreter rounds `a + (b - a) * t` twice (`VM/src/lmathlib.cpp:444`,
     `lbuiltins.cpp:1744`). A `--!native` server and an interpreted client can therefore disagree on any
     computation that lerps. The closed-form projectile, `sin`, `atan2` and `exp` hashed equal in both modes.
   - f32 against f64: the same projectile formula on `vector` (Roblox `Vector3` is f32) and on numbers differs by
     up to 9.78e-5 studs per component. At step 1/32, 154 of 300,000 components (0.051%) fail tolerance 0;
     **none** differ by more than one step.
   - Across devices (arm64 clients, x64 servers, other libm builds): **unverified**. The attempt's probe ran on
     one Windows machine only (`v5-attempt.md` §5); a Roblox staff post says float results are not guaranteed to
     match across hardware (reported there). Whether Roblox's interpreter is compiled with FP contraction on arm64
     is **unverified**; if it is, arm64 clients fuse where x64 clients don't.
   - With tolerance ≥ one step, this cause vanishes while the float gap stays below one step.
2. **A different algorithm.** Client code that integrates per frame while `fn` uses the closed form, after 1 s of
   flight at Roblox's default gravity 196.2 studs/s²: 3.27 studs off at 30 FPS, 1.64 at 60, 0.68 at 144, 0.41 at
   240. The error depends on the client's frame rate, so it differs by device. Fix: both sides call one shared
   function (closed form, or a fixed step).
3. **Inputs quantized after the client used them.** The client computes from its raw aim, then sends
   `t.direction(10)`; the server recomputes from the decoded aim. At 300 studs of flight, 0.2369° is 1.24 studs
   (derived: 300 × tan 0.2369°). Fix: compute the outcome from the value as it will decode. Lync has no client call
   that rounds a value through a codec; adding one (a codec method, say `:round(value)`) is a small API decision
   for the lead.
4. **Server state that differs from the client's.** When `fn` reads server state: latency (CT C1, cause 1),
   parts the client hasn't streamed in, moving geometry.
5. **Inputs that weren't sent.** The client used its own clock, a random draw or local state the message doesn't
   carry. Fix: put them in the message (a seed, `Lync.tick()`), and check them with `within`.

### U9.7 The fact

`constraint` (CT C0), with **`kind` 4 = `derive`** appended to C0's list. The evidence set doesn't change:

| Field | `derive` meaning |
|---|---|
| `check` | 1-based index among the definition's checks |
| `kind` | 4 |
| `policy` | 1 drop, 2 clamp, 3 deliver |
| `observed` | d, in the field's unit, after snapping (1 for an unequal `t.enum` or `t.bool`) |
| `bound` | `tolerance` |
| `late` | 0 |

Exact trigger: §U9.4 step 4. Action: by `policy`. Known causes: §U9.6. Evidence values are pre-clamp, numbers only,
from the decoded value and `fn`'s result, never client bytes.

### U9.8 Cost

Measured (`server_facts_cost.out`, 2 runs per mode), per message:

| Line | Native | Interpreted |
|---|---|---|
| the game's `fn` alone (closed-form projectile on `vector`) | 13.0–19.1 ns | 40.7–41.3 ns |
| runner baseline, definition with no checks | 6.9–7.0 ns | 18.6–19.4 ns |
| runner + `fn` + snap + Euclidean compare (the design) | 31.9–32.3 ns | 92.3–95.1 ns |
| the same, compared in steps (Chebyshev), not chosen | 38.2–40.1 ns | 113.7–119.2 ns |
| runner + exact compare (`t.enum`) | 7.2–8.5 ns | 23.8 ns |

- Lync's share for a vector field (runner minus `fn` minus baseline): about 6–12 ns native and 32–36 ns
  interpreted. Add the `xpcall` (+18–38 ns, DIAG §9) when the definition has no validator, and 20.5 ns per failure
  for the fact record (DIAG §5.2).
- `fn` is the game's cost. A simulation with raycasts costs what `Workspace:Raycast` costs (unmeasured on Roblox,
  AC Implications). `oneIn` controls it.
- State: 0 B. Wire: 0 B. Build: none.

### U9.9 Least work for the game developer

- One server line per claimed field, passing the function the client already calls from a shared module.
- Start with `policy = "deliver"`, read `observed` over a play session, set `tolerance` from §U9.5's formula, then
  choose `drop` or keep `deliver`.
- The docs' two rules: compute the claim from values as they decode (cause 3), and share one function between
  client and `fn` (cause 2).
- Relation to `:claim()`: a field that a `derive` covers is a claim. Whether a `derive` or `within` on a
  `:claim()` field satisfies C0's "a definition with claim fields must have `validate`" is CT C4's decision. I'd
  recommend it does, so a game doesn't write an empty validator just to satisfy the rule.

### U9.10 Options

`Net.<definition>:derive(path, options)`, server view; client-sent events and request asks (CT C0's scope).

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `path` | string | — | a field of a codec in §U9.4, through records and optionals | required | none |
| `fn` | `(Player, Data) -> T?`, T the field's decoded type | — | — | required | the game's own, per checked message, inside the validator's `xpcall` |
| `tolerance` | number (real) | the field's unit | 0–2^31; 0 only for `t.enum`, `t.bool` | required | none |
| `policy` | `"drop" \| "clamp" \| "deliver"` | — | — | required (CT C0: no default) | clamp: 53–63 ns per clamped vector (CT C6) |
| `oneIn` | integer | messages per check | 1–1000 | 1 (every message) | above 1, a random draw per message (24–32 ns, INT §4) and `fn` runs on 1/`oneIn` of them; unchecked messages pass |

Caller errors (CT C0's family): `unknownField`, `checkKind`, `checkOption`.

**Types.**
- Generated Luau shard (both solvers): `derive` is an intersection of one overload per accepted path, each with
  its own `fn` return type, e.g. `((self, path: "landing", options: DeriveOptions<ShotData, Vector3>) -> ()) &
  ((self, path: "flight", options: DeriveOptions<ShotData, number>) -> ())`. `DeriveOptions<D, T>` is
  `{ fn: (Player, D) -> T?, tolerance: number, policy: "drop" | "clamp" | "deliver", oneIn: number? }`.
  Intersections of function types are overloads on both solvers; whether the old solver picks the overload from a
  string-literal argument without an annotation is **unverified** and is milestone 3's typing proof, beside
  CT C0's path union.
- Runtime path, new solver: a type function from the literal path to the field type; old solver: `T` is `unknown`.
- roblox-ts: overloads, `derive(path: "landing", options: DeriveOptions<ShotData, Vector3>): void;` per path, with
  `this: void` dot calls as in `v5.md` §3.6.

---

## U10. `reactsTo`: response before stimulus, and the reaction floor

### U10.1 What it is, what it protects

- **Mechanism.** A client-sent definition declares, on the server view, which server-sent definition it answers:
  `Net.collect:reactsTo("coins", { key = "coin" })`. For each response, the server finds the stimulus it answers
  and reports a fact when the response arrived before that stimulus could have reached the client, or sooner after
  it than a declared floor (AC §4.3).
- **What it prices.**
  - Response before stimulus: a client acting on data Lync hadn't delivered, which leaves three sources. It predicted
    the stimulus (a bot pre-firing a timed prompt). It got the data by another path (engine replication, a leak). Or
    it fires the response blind, without a stimulus (an auto-collector firing "collect" on every key). AC §4.3 calls
    this strong when the data exists only in Lync.
  - The floor: responses faster than a human could make them, on definitions only a human should answer.
- **Defeated by** (capability class): a client that waits for the stimulus and then answers at a human-looking
  delay. The fact prices speed, not automation. A modified Lync runtime can also misstate the receipt (§U10.2); the
  time rule still bounds it.

### U10.2 Decision: how the server knows when the stimulus reached the client

| Source | What it says | Exact? | Exists today | Cost |
|---|---|---|---|---|
| **Time** | the stimulus left at t_s (Lync's flush); the response was decoded at t_r; any response needs at least the round trip, so elapsed = t_r − t_s is at least the path | no: bounded by a ping estimate | yes: `earlyAnswer` uses it (INT §7) | none on the wire |
| **State-frame acks** | the newest `:newest()` state frame received, with a 16-bit history (`v5.md` §4.1); IR §11.3 makes every frame carrying a `perceived` message carry a full ack | yes, for state frames | yes | 28 bits per carrying frame (IR §11.3) |
| **Reliable receipt** (new) | how many downstream reliable frames the client had decoded when it built this frame | yes, for reliable stimuli answered on the reliable lane | no: reliable frames are not acked (`v5-collections.md` §1, IR §11.8) | 1 B per upstream reliable frame |

- State-frame acks don't help here. A stimulus is a discrete event or a record's add, and both travel on the reliable
  lane (`v5-collections.md` §1: structure and reliable fields are reliable, with no acks). `:newest()` rows are
  continuous state, not stimuli.
- **Choice: time always, plus the reliable receipt.** Time works on every lane and needs nothing new. The receipt
  makes "before stimulus" exact for reliable stimuli: no ping estimate, no smoothing error. In `reaction_sim.out` it
  catches every response sent before the stimulus arrived, where the time rule catches only those fired before
  the stimulus left the server (table in §U10.6).
- **The receipt, exactly.** `header (up, reliable) := ack rcv:u8`, where rcv is the client's count of downstream
  reliable frames decoded (refused frames included), mod 256, when it builds the frame. The server extends it to
  the value in (S − 256, S], where S is its count of reliable frames sent to that player (`FireAllClients` frames
  count for each recipient; each split frame counts).
  - It is on **every** upstream reliable frame, so it shows nothing about which definitions are watched.
  - Aliasing (a client more than 255 frames behind, a stall over 4.2 s at 60 frames a second) extends upward. A
    stimulus then reads as received, which can only miss a fact, never make one.
  - It is client-stated. A modified runtime can overstate it, and then only the time rule applies. Bots driving the
    unmodified runtime through its API (the common case, INT §1) can't.
  - It changes the upstream reliable header of `v5.md` §4.1. That is milestone 2's frame format and golden set,
    so it lands there, or in milestone 5 with a protocol version change.
  - Side benefit: IR §11.8 returns reliable fields at Q, "on the assumption that the reliable lane is as current as
    state frames … Lync can't tell". The receipt tells it.

### U10.3 Declaring, and pairing a response with its stimulus

```luau
-- server view
Net.collect:reactsTo("coins", { key = "coin", floor = 0.12 })   -- a collection: the record's add to this viewer
Net.answer:reactsTo("prompt", { key = "id", floor = 0.15 })      -- an event: data.id equals the prompt's data.id
Net.dodge:reactsTo("telegraph", { key = { response = "attack", stimulus = "attackId" } })
```

- **Response:** a client-sent event or request ask. **Stimulus:** a server-sent event (either lane) or a collection
  (the stimulus is the record's add to that viewer). A server request as stimulus is `checkKind`: `earlyAnswer`
  covers it. A field change as stimulus (a door's `open` turning true) isn't designed here.
- **`key` is required.** Without a key a response can only be paired with "the newest stimulus", and with frequent
  stimuli and a slow answer that is the wrong one: the estimate comes out short and the floor fires on an
  unmodified client. A key pairs exactly. For a collection it is the response field holding the record key, the
  same shape as `refers` (INT §8). For an event it is a path present in both (`"id"`), or two paths. The two codecs
  must be equal, else `checkKind`.
- **Candidates.** Events: the stimuli with that key among the last `track` sent to the player. Collections: the
  record's **first** add to this viewer in its current incarnation (a re-add after a remove keeps the first).
  Whenever several candidates qualify, Lync uses the **oldest**: it gives the longest elapsed time, so pairing
  errors can only miss facts.
- Like `:trap()` and `:refers()`, it is a server-view declaration: not in the shared schema, not hashed, invisible
  to the client.

### U10.4 Triggers, exactly

All times are server `os.clock()`. t_s is the flush that handed the stimulus's frame to the engine (for a held
send, the flush that released it). t_r is the decode of the response's frame. bound is the path lower bound below.
1. **Case 3, never sent** (collections only): the key names a live record whose current incarnation was never
   added to this viewer.
2. **Case 1, before stimulus:**
   - exact: the response came in a reliable frame, every candidate is a reliable stimulus, and every candidate's
     frame number is greater than the extended receipt;
   - else by time: t_r − t_s of the oldest candidate < `factor` × bound.
3. **Case 2, below the floor:** `floor` > 0 and (t_r − t_s) − bound < `floor`, measured to the oldest candidate
   the receipt shows received (or the oldest candidate, without a receipt).
4. Otherwise nothing. A key with no candidate (an event stimulus outside the ring, a record no longer live) counts
   `reactionsUnmatched` and raises no fact.

**bound**, per player: the minimum, over the last 10 s, of `Player:GetNetworkPing()` samples (one at each stimulus
send to the player) and of Lync's own ack round trips where state frames flow (IR §11.3). Engine ping "doesn't
involve data deserialization or processing" (documented, `Player.yaml`), so it sits below the full path, which errs
toward missing. The ack round trip includes client hold time and isn't smoothed, so it tracks a latency drop within
one state frame. The estimate is reaction = elapsed − bound ≥ the true reaction whenever bound ≤ the true path
(§U10.6). The same bound should replace `earlyAnswer`'s ping-only minimum (INT §7), so the two agree.

### U10.5 Where it runs, and the fact

**Pipeline** (`v5.md` §6.1): step 5's report-only checks of milestone 5, beside `decoyReferenced` and
`canaryEchoed`, after `limit` and the `checks` block. The message is **always delivered**: R25 refuses
library-applied drops for timing facts. Stimuli are recorded in the flush, where each player's frame is built.

| Reason | Exact trigger | Action | Evidence | Known causes on an unmodified client |
|---|---|---|---|---|
| `earlyReaction` | §U10.4 case 1, 2 or 3 for a message of a definition with `reactsTo` | delivered | `case` (1 before stimulus, 2 below floor, 3 never sent), `exact` (1 decided by the receipt or by never-sent, 0 by time), `elapsed` (s, t_r − t_s; −1 in case 3), `minPing` (s, the bound used), `floor` (s, 0 when off), `behind` (frames: candidate frame − receipt in exact case 1, else 0) | below |

The code follows `earlyAnswer`'s name and `slotConflict`'s `case` pattern. Evidence is numbers only and narrows on
`reason` alone (`v5.md` §7.3).

**Known causes on an unmodified client:**
- **Every case:** game code acting on the same information delivered another way: the entity replicated through
  Workspace, another remote, or a client timer that knows when the stimulus comes (a round countdown).
- **Case 1, exact:** a key the game reuses for more than `track` stimuli while an older one is still being
  answered, which leaves only newer candidates; a Lync bug.
- **Case 1, by time:** the causes above, plus a bound above the true path: `GetNetworkPing` is smoothed and lags a
  sudden latency drop (INT §10, by how much is unmeasured) where no ack round trip is available. On `v5.md` §9's
  default network it fired 0 times in 200,000 instant responses at bounds 0.10 s and 0.12 s.
- **Case 2:**
  - game code answering without a human (a response fired from the stimulus handler);
  - stimuli a player can predict;
  - humans faster than the floor. The floor is the game's: athletics treats a reaction under 0.100 s to the
    starting gun as a false start (World Athletics TR16.6, 2020 edition, as quoted by
    [FinishLynx](https://www.finishlynx.com/product/reactime-championship-software/), reported), and visual reactions
    are slower;
  - a bound above the true path: at 0.02 s above it, the estimate fell up to 0.018 s below the true reaction, and
    1.35% of 0.10 s reactions read under a 0.10 s floor.
- **Case 3:** as "every case": the game shows the entity by another path while the viewer's audience, or
  `interest` relevancy, excludes the record from Lync.

### U10.6 What the triggers catch, and their noise (simulated)

`reaction_sim.out`, `v5.md` §9's default network (latency 0.05 s, jitter 0.02 s, 0.3 s stalls at 0.05 per s),
60 Hz client and server steps, 200,000 trials per line.

| Responder | Slack (estimate − true reaction): min / p1 / p50 / p99 | Below a 0.10 s floor |
|---|---|---|
| unmodified, reaction 0 (automatic), bound 0.10 s (= the true minimum path) | 0.004 / 0.019 / 0.045 / 0.240 s | 97.6% |
| unmodified, reaction 0.15 s, bound 0.10 s | 0.005 / 0.019 / 0.046 / 0.246 s | 0% |
| unmodified, reaction 0.10 s, bound 0.12 s (0.02 above the true path) | −0.018 / −0.001 / 0.026 / 0.223 s | 1.35% |

| Fires at L after the stimulus left, without waiting for it | Case 1 by time (factor 0.5) | Case 1 by receipt | Floor 0.10 s |
|---|---|---|---|
| L = −0.20 s | 99.3% | 100% | 100% |
| L = 0 | 0% | 100% | 99.2% |
| L = +0.03 s | 0% | 100% | 98.9% |
| L = +0.06 s | 0% | 16.3% | 98.8% |

- With bound at or below the true path, slack is never negative: a fact implies a true reaction below the floor.
  Stalls give the long positive tail, so 2.4% of automatic responses escape a 0.10 s floor.
- Flush and step granularity (up to 1/60 s each at the client's dispatch, the client's flush and the server's
  decode) and processing time only lengthen elapsed, so they only miss facts.

### U10.7 Cost

Measured (`server_facts_cost.out`, 2 runs per mode):

| Operation | Native | Interpreted | When |
|---|---|---|---|
| record a stimulus: ring push (key, frame, time) | 8.6–10.2 ns | 77.4–78.7 ns | per recipient per event stimulus (100 recipients ≈ 1 µs native) |
| response to an event: scan 8 entries, tests | 34.7–38.1 ns | 178.5–181.6 ns | per response |
| response to a collection add: slot frame, frame time, tests | 8.2–8.3 ns | 49.2–54.5 ns | per response |
| bound: record a ping sample | 7.9–8.1 ns | 46.2–47.5 ns | per stimulus sent |
| bound: minimum of 10 one-second buckets | 45.4–46.0 ns | 191.9–193.3 ns | per response (can be cached per second) |

- Plus one `GetNetworkPing` call per stimulus sent (cost on Roblox unmeasured), 20.5 ns per fact occurrence
  (DIAG §5.2), and for collections one u32 write per add to each viewer.
- **Memory:** event ring 24 B × `track` per (player, declaration) (192 B at 8; string keys add a reference); per
  watched collection 4 B per (viewer, slot), 4 KB per viewer at 1024 slots, 400 KB at 100 viewers; per player a
  ring of the last 256 reliable frames' send times (2 KB; an add older than it can't be fast, so it raises no fact)
  and 40 B of ping buckets.
- **Wire:** the receipt, 1 B per upstream reliable frame: at most 120 B/s at the default reliable frame budget,
  60 B/s at 60 automatic flushes. Nothing else.

### U10.8 Least work for the game developer

- One server line per response definition. The key usually exists already: a record key, a prompt id. The shared
  schema doesn't change.
- Leave `floor` at 0 (only cases 1 and 3) unless the response is human-gated. When it is, the docs' rule: floor ≤
  the fastest human reaction the game accepts, minus 0.02 s for bound error.
- Read `elapsed` and `minPing` over real sessions before setting a floor. Aggregated, they are a distribution
  feature (AC §4.3), not a per-event verdict.

### U10.9 Options

`Net.<response>:reactsTo(stimulus, options)`, server view.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `stimulus` | string | — | a server-sent event or a collection of the namespace (`unknownField` otherwise, as `refers`) | required | collections: 4 B per (viewer, slot) |
| `key` | string, or `{ response: string, stimulus: string }` | — | field paths with equal codecs (`checkKind`) | required | none |
| `floor` | number (real) | s | 0 (off) or 0.01–2 | 0 | none beyond the response test |
| `factor` | number (real) | fraction of the bound | 0 (off) to 1 | 0.5 (as `earlyAnswer.factor`) | none |
| `track` | integer | event stimuli remembered per player | 1–64 | 8 | 24 B per entry per player; the response scan is linear in it (35–38 ns native at 8) |

Constants: bound window 10 s (as `earlyAnswer`); frame-time ring 256 frames per player. Counter:
`reactionsUnmatched`. Caller errors: `unknownField`, `checkKind`, `checkOption` (CT C0).

**Types.** Generated Luau shard: one overload per stimulus name, each taking only the key paths whose codec matches
that stimulus's key, e.g. `((self, stimulus: "prompt", options: ReactsToOptions<"id">) -> ()) & ((self, stimulus:
"coins", options: ReactsToOptions<"coin">) -> ())`, with `ReactsToOptions<K>` = `{ key: K | { response: K,
stimulus: string }, floor: number?, factor: number?, track: number? }`. roblox-ts: the same as overloads with
`this: void`. Runtime path: strings checked at the call. Old-solver overload selection by literal is milestone 3's
typing proof, as for `derive`.

---

## Implications (U9, U10)

1. Adopt `derive` as `checks` kind 4, `Net.<definition>:derive(path, { fn, tolerance, policy, oneIn })`, reported
   as `constraint`, rather than the research's `Lync.derive` value or a `within` recipe (§U9.2).
2. Snap `fn`'s result through the field's quantizer before comparing; that is what makes a one-step tolerance
   absorb float noise (§U9.4, §U9.6 cause 1).
3. Tolerance in the field's unit, as `within`; document one grid step as the smallest useful value, never 0, on
   quantized codecs (§U9.5; 0.051% of f32/f64 components straddle, none by two steps).
4. Document that `--!native` servers and interpreted clients disagree on `math.lerp` and `vector.lerp` (FMA), and
   run the cross-device float probe on arm64 clients before any doc claims more (§U9.6 cause 1).
5. Decide whether codecs get a client-side `:round(value)`, so claims can be computed from values as they decode;
   without it, input quantization is the largest cause a developer can't fix alone (§U9.6 cause 3).
6. CT C4 should let a `derive` or `within` on a `:claim()` field satisfy the "must have `validate`" rule (§U9.9).
7. Adopt `reactsTo(stimulus, { key, floor, factor, track })` on the server view with `key` required; pairing
   without a key raises facts for unmodified clients (§U10.3).
8. Add the reliable receipt (`rcv:u8` in every upstream reliable header) to milestone 2's frame format: 1 B per
   reliable frame buys an exact "before stimulus" and fixes IR §11.8's reliable-field gap (§U10.2, §U10.6).
9. One fact, `earlyReaction`, with `case` 1–3 and `exact`, always delivered, never dropped (§U10.5).
10. Use one path bound, min(10 s of `GetNetworkPing`, Lync's ack round trips), for both `earlyReaction` and
    `earlyAnswer`; the floor is only conservative while that bound stays at or below the true path (§U10.4,
    §U10.6).
11. Ship `floor` off by default and document the margin rule (floor − 0.02 s); never ship a default human floor
    (§U10.5, §U10.8).
12. Still unmeasured on Roblox: `GetNetworkPing`'s smoothing and per-call cost, `Workspace:Raycast` inside `fn`,
    and whether the engine sends at the flush (`v5.md` §10). Each one changes the strength of a known cause, not
    the design.
