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
- [ ] U10. `reactsTo`: response before stimulus, and the reaction floor
- [ ] Implications (U9, U10)
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
