# Review of the v5 design, draft 1

Reviewed: `.data/docs/design/v5.md` as it stood on 2026-10-15 after the lead's in-flight edits:
- `t.flags` removed;
- single-row sections use fixed-width bits (§4.3);
- `maxRate` removed;
- no audience-by-field shortcut;
- `collection` settled;
- §5.1 rewritten, with `flush()` optional;
- §6.4 rewritten with per-reason triggers and weights;
- principle 5 ("precise, never simplified") added.

Evidence: the research briefs, `probes/typing-and-codegen`, and new probes in `probes/review-1/`. The new probes
were checked with luau-analyze 0.740 through the luau skill's pinned toolchain. Each one says in a header comment
what it tests (index at the end).

**Count:** 3 blocking, 13 major, 11 minor, 4 taste.

---

## Blocking

### B1. Skippable sections can't coexist with a shared byte tail, the intern table, or rate-before-decode

**Severity:** blocking (milestones 1 and 2 wire format).

**The case.** §4.1 promises that "a bad or unknown section is skipped [by its length prefix], not fatal to the
frame". Three other parts of the design keep state that crosses section boundaries:
1. **Byte tail.** Strings and buffers are "length code + bytes in the byte tail" (§3.3, §4.3), and there is one
   tail per frame. Take a frame with sections A (`chat`, 1 string), B (unknown kind) and C (`chat`, 1 string). If
   B is skipped by its length, the decoder doesn't know how many tail bytes B owned. C's string is then read from
   B's bytes, or its range check fails. So a single skipped section corrupts or drops every later section that
   holds a string.
2. **Intern table.** The table is "append-only ... per-connection ... needs no eviction messages" (§4.4), which
   works only if both ends apply every insertion in order. Suppose a skipped or refused section held the first
   occurrence of `"sword"`, entry 41. Every later reference to 41, in this frame and for the rest of the
   session, now resolves to the wrong string or to nothing. That includes a refusal at step 5 or 6 of §6.1 if
   the insertion is applied only on delivery.
3. **Rate.** The schema comment in §3.4 says `rate` is "enforced on the server before decode". §6.1 runs it at
   step 5, after the step-4 decode. Single-row events have no per-message length, so a message can't be skipped
   before it is decoded. Decoding it anyway is what keeps the tail cursor and intern table in step.

**Why it matters.** Recovering from one bad section is the main robustness argument in §4.1, and also the cure
the attempt brief prescribed (`v5-attempt §10.6`). As written, the recovery can't work. Milestone 1 would bake in
a frame format with this flaw.

**Fix (smallest):**
- Give each section its own tail span: the header carries `bitLength` and `tailLength`, or the tail is laid out
  per section in section order with its length in the header. Skipping then advances both cursors.
- Apply intern insertions in the decoder, before any refusal. Then refuse the *frame* rather than skip the
  section whenever a section that may insert is malformed. Alternatively, turn interning off upstream (see M5),
  so the server never mirrors client insertions.
- Change the §3.4 comment to "enforced before delivery". Charging before decode is already done by the
  per-player byte budget at step 2.

### B2. State on a 20 Hz tick breaks "every event sees the state it refers to"

**Severity:** blocking (milestone 4 semantics, plus a guarantee stated in §4.1).

**The case.** Server code at frame N, where N is not a state tick:
```luau
Net.fighters:set(7, { ... })
Net.announce:fire(Lync.all, { kind = "spawned", id = 7 })
```
§5.1: "A flush includes state only when a state tick is due". With `stateRate = 20`, a state tick falls on every
third frame. The event leaves in frame N, and the add leaves at frame N+1 or N+2. The client's `announce`
handler calls `Net.fighters:get(7)` and gets `nil`. §5.3 adds a second way to break it: under budget pressure the
add can be deferred for up to `maxPendingAge` (2 s), while events are never deferred.

**Why it matters.** §4.1 states the guarantee, and game logic will rely on it. State-sync §3.8 actually
recommends "every frame (60 Hz) for events, replies and **reliable structural changes**". The design dropped the
structural part without saying so.

**Fix:** split the work across two clocks:
- Every frame: structural changes (add, remove, audience change) and exact reliable fields, in the §4.1 order.
- On the state tick: `:newest()` fields and the scheduler.
- Exempt structural changes from deferral. Charge them like events, so the budget defers only field updates.
- Document the remaining non-atomicity between reliable and `:newest()` fields (state-sync §5.3 item 4).

### B3. The column coder's prediction contradicts the notify model it is supposed to serve

**Severity:** blocking (milestone 1 builds the coder; milestone 4 depends on it).

**The case.** §4.3 claims "motion fields use guarded linear prediction, which halves position bits". In
practice:
- **Motion fields don't use the lane prediction needs.** In the §3.4 example, `position` and `look` are
  `:newest()`. §5.2 sends those as "absolute quantized values encoded once per tick" with "per-viewer dirty
  bits". Compression §4.3 states the constraint: "On the unreliable lane, prediction must use acked baselines
  ... Sending a residual against the *previous sent* frame is unsound without acks". Absolute values plus
  notify give the predictor no baseline at all. Per-viewer acked baselines are exactly what state-sync §1.2 kept
  out of the core.
- **Encode-once and column coding don't mix.** A column's mode and k are chosen over the rows in that frame.
  Notify picks a different row subset for each viewer (per-viewer dirty bits, budget, priority), so each viewer
  gets different columns, a different k and a different bitstream. That is per-viewer encoding. The encode-once
  measurement (state-sync §3.6) copies fixed row chunks, which a column layout doesn't have.
- **The headline numbers come from a different scheme.** `col_bits_pred`'s 1.3–2.4× win (compression §2.1)
  used reliable age-1 deltas, or acked baselines at 150 B against 102 B. Absolute `:newest()` values in column
  form were never simulated.

**Why it matters.** The two briefs disagree, and the design adopts both without reconciling them. Milestone 1
would spend most of its effort on a predictor and k search that milestone 4's replication model can't use.

**Fix.** Pick one per lane and say so:
- **Reliable sections** (structure and exact fields, encoded once per audience): column coding with age-1
  prediction is sound here, and it is where the measured win applies.
- **`:newest()` sections:** row-wise fixed-width records, encoded once per tick, so a viewer's selection is a set
  of `buffer.copy` chunks, as measured. An alternative is column FOR over absolute values per viewer, with its
  cost measured.
- Before milestone 1, re-run `sim_layout.py` for notify-with-absolutes so §4.2's claim cites the configuration
  actually chosen.

---

## Major

### M1. Option-table definitions don't infer the way §3.1 and §3.5 claim (runtime path, new solver)

**The case** (probes `r1`, `r2`, `r5`, `pipe/`):
- **`from` widens.** With `event<D>(def: D)`, the literal `from = "client"` arrives as `string`, and so do
  `timestamped = true` (as `boolean`) and `lane = "unreliable"` (as `string`) (`r1`). No type function can then
  choose methods from `from`.
- **A fix exists for `from` only.** The signature `event<D>(def: D & { from: "client" | "server" })` keeps
  `"client"` exact and rejects `"clinet"` (`r2`, `r5` case i). Through the full pipeline (`pipe/`), the server
  view then gets exact handler parameters and rejects a wrong-side `fire`, a wrong union variant and an extra
  handler parameter.
- **Options still widen.** `timestamped` and `lane` still widen under that signature (`r5` case i). So
  "`timestamped` definitions add one trailing typed argument" (§3.5) can't be inferred.
- **Typing the options breaks the check.** Adding `lane`, `timestamped` and `rate` to the expected type
  produces spurious errors on valid literals, such as "Expected property `rate` to be exactly `nil`" (`r5`
  case ii).
- **Option typos pass.** `timestampd = true, rtae = 5, lnae = "unreliable"` gives no diagnostic (`r5` case v).
  That contradicts §3.1: "Every definition option has a name the type checker and autocomplete know".
- **The intersection is fragile.** The same intersection on `Lync.request` raised a spurious "Expected this to
  be exactly `D & {...}`, but got `"client"`" whenever the return type was `RequestDef<D>`. This happened both
  top-level and nested (`pipe/buyonly.luau`, every line). A simpler return type in isolation was clean (`r6`,
  `r7`). I didn't isolate the trigger, so treat this signature as unproven for production.
- **The generated path doesn't escape this.** The schema module itself is always checked against the runtime
  `Lync.event` types, and on the old solver those types are `--!nocheck` stubs.

**Fixes:**
- Use `D & { from: "client" | "server" }`, and have the planner throw on unknown option keys with the definition
  path. That is the only place typos can be caught.
- Remove `timestamped` as an option. Make the stamp a payload codec,
  `data = { at = t.subtick(), target = ... }`, which `Infer` types like any field and which needs no handler
  arity rule.
- Add a probe for request and collection signatures before milestone 2.

### M2. "`patch` is generic over the literal, so a misspelled key ... is a compile error" is false on every path

**The case:**
- **Runtime path.** Put the T4b generic method (`patch: <P>(self, id, p: P) -> StrictPatch<P, T>`) inside a
  definition that the side-view type function selects, and the whole view collapses. Every key, including
  `fighters` and its `set`, reports "does not have key", next to "Type functions do not currently support types
  of the form `StrictPatch<P, Rec>`" (`r3`). Used directly, outside a view, the same method works.
- **Generated path.** A concrete `FighterPatch = { name: string?, health: number?, title: string? }` accepts
  `{ healht = 90 }` on both solvers (`r4`), as T4 already found.
- **What does work.** A non-generic `Partial<T>` on the runtime path rejects wrong value types (`pipe/server.luau`
  line 28) and accepts typos (line 27).

**Fix.**
- State the truth: wrong value types are compile errors; misspelled keys are caller errors thrown at the
  caller's line (§3.8).
- If static typo checks matter, the generated path can emit a per-field overload set:
  `((self, id, "health", number) -> ()) & ((self, id, "name", string) -> ())`. Weigh it against the API's
  beauty before adopting it.

### M3. One word, several meanings (principle 4)

| Spelling | Meaning 1 | Meaning 2 | Meaning 3 |
|---|---|---|---|
| `rate` | event/request option: inbound token bucket, messages per second (§3.4) | codec marker `:rate(hz)`: outbound send cap per field (§3.6, §5.3) | `stateRate`; collection `rateHz` option for scheduling |
| `t.map` | `t.map(key, value, maxCount)`: dictionary codec (§3.3) | `t.map(base, decode, encode)`: transform (§7.1) | — |
| `newest` | event option `newest = true`: only the latest value per recipient, on any lane | field marker `:newest()`: unreliable lane + notify repair | — |
| `priority` | collection option `priority` | field marker `:priority(w)` | — |
| `:input()` | security role of a client→server field (§6.3) | the state-sync input-stream mode, now implicit in every client `lane = "unreliable"` event (§5.2; see M4) | — |
| `owner` | `:owner()`: a priority boost (§3.6) | the `interest` visibility class `owner` (§7.3) | state-sync §3.10: "only to the owning player" |

Concrete harm: `rate = 5` on an event *drops* the sixth message. `:rate(5)` on a field *delays* the next update.
A user who learned one will misread the other.

**Fix (proposed spellings):**
- Inbound: `limit = { perSecond = 5, burst = 10 }`. "Limit" is the attempt's word, and it names a refusal.
- Outbound: `:maxHz(20)` on a field and `maxHz = 20` on a collection. Drop `rateHz`.
- Transform: `t.convert(base, decode, encode)`.
- `newest`: make the event form mean exactly what the field marker means (unreliable lane, latest wins, notify
  repair). Otherwise give the reliable "coalesce" behaviour its own name, such as `coalesce = true`.
- `owner`: one meaning only (see m7).

### M4. Every client `lane = "unreliable"` event silently becomes a redundant, delayed input stream

**The case.** §5.2's last row turns any unreliable client event into an input stream: "every input since the last
ack, delta-coded, capped at 32; a server jitter buffer of 2–5 ticks". The design's own `strike` is a one-shot
action. Under this rule:
- **Copies.** The client re-sends it in every upstream frame until acked: about 6 copies at 100 ms RTT and
  60 Hz, up to 32.
- **Delay.** The server holds it 2–5 ticks before the handler runs. Lag-compensated hit checks pay that delay
  twice.
- **Wrong source.** State-sync recommended an opt-in `:input()` stream for continuous control state, not for
  discrete intents. The anticheat brief (§3.2) adds that under Server Authority, simulation inputs belong in
  InputActions.

**Why it matters.** "Unreliable" stops meaning "may be lost, arrives early". The cost is per message multiplied
by RTT/frame, on the hot path. The jitter buffer's tick (frame or state tick?) and its adaptivity aren't defined.

**Fix.** Keep `lane = "unreliable"` plain. Make redundancy explicit, with its parameters stated per principle 5:
`resend = { maxCopies = 32 }, jitterBuffer = { ticks = 3 }`, both off by default. Rename the security role from
M3 so the word `input` isn't used twice.

### M5. The intern table is a per-player memory sink and fills with junk

**The case:**
- **Memory.** It is "per-connection, append-only ... at most 4096 entries" (§4.4), capped by count, not bytes.
  Upstream, a client that sends 4096 distinct `t.string(200)` values pins about 800 KB on the server. With a
  `t.string(4096)` field, about 16 MB per player; 100 players reach 1.6 GB. Nothing in §6.1's budgets bounds
  retained memory, only inbound rate.
- **Junk.** Compression §5 found that chat must be marked "transient" (non-internable). The design dropped the
  marker, so every unique chat line takes a slot. Once the table hits 4096 it "stops interning", and item names
  that first appear late in a session are never interned.
- **Unreliable lane.** §4.4 doesn't say what an unreliable frame may reference. The brief's rule ("only ids the
  receiver has acked; otherwise inline") is missing.

**Fix:**
- Intern server→client only.
- Cap by bytes as well as count.
- Intern only fields declared internable. Inversion is safer: `t.string(20, { intern = true })`, or the
  vocabulary goes in `t.enum`.
- Adopt the brief's unreliable-lane rule.
- Leave templates out until they have a syntax (see M10).

### M6. "Game code requires the shard" contradicts the build brief and makes stale fallback a type lie

**The case.** Client-security-build §2.4 says `Lync.client(ns)` and `Lync.server(ns)` return the same views
either way, and "a generated shard supplies codecs to the view; it never replaces the API". The design makes the
shard the API (§3.2, §3.5). Then:
- **Fallback needs the full runtime.** When the shard is stale, §4.5 says both sides "fall back to the runtime
  path together". So the shard must contain or require the full runtime planner and the live schema, and compare
  hashes on load.
- **The types lie.** Game code keeps the stale shard's concrete types while running the live schema. A field
  renamed in the schema is still typed under its old name, and the call throws at run time.
- **Agreement is assumed.** "Both sides agree" needs both shards to detect staleness identically. That holds
  only if both compare against the same evaluated schema, and the design doesn't say so.

**Fix.**
- Either follow the brief (game code always calls `Lync.server(schema)`, and the shard is found by rule and
  supplies codecs), or keep shards as the API and make a stale shard a loud error in Studio and in `lync check`,
  not a silent fallback.
- Pick one, and state which module game code requires on each path.

### M7. Notify acks can't identify downstream frames, and "sequence intact" has no sequence

**The case.**
- **Shared tick.** The ack is `u16 tick + u32 bits` (§5.2) and identifies frames by tick. Several unreliable
  frames can share a tick: the 4× join burst is 3,200 B per tick at 20 Hz, which needs four frames under the
  1000 B cap, and so does any tick over 1000 B. The server can't tell which of the four was lost, so notify
  can't re-dirty exactly "what has not been superseded".
- **Missing sequence.** §4.1: "a single item that can't fit is demoted to the reliable lane with its sequence
  intact". No sequence exists in the downstream frame format, only the header `tick`.
- **Unclear rule.** "One flush produces one frame per player per lane" (§5.1) contradicts §4.1's splitting.

**Fix.**
- Give downstream unreliable frames a u16 frame sequence, and ack that instead of the tick.
- Carry the tick in the header for alignment.
- Define demotion as "the item travels in the reliable frame with its tick; newest-wins compares ticks".
- Say "at most one reliable frame per player per flush; unreliable frames split at 1000 B".

### M8. Verifiers in the shared schema, and codec methods multiply

**The case.**
- **Claim verifiers.** §6.3 declares claims as a codec method `:claim(verifier)`, in the shared schema. It also
  says "Behaviour, such as validators and claim verifiers, stays server-only". A verifier that touches server
  state (`ServerStorage`, DataStores, game services) makes the shared schema fail to `require` on the client. Its
  code also replicates to clients. The anticheat brief (§3.2) put the verifier on the *server view*.
- **Codec methods.** §3.3 says "The only codec methods are the state-field markers in §3.6". §6.3 adds `:input()`
  and `:claim()`, §7.3 adds `:aim()` and `:atom()`, and §11 floats `t.optional` as a method.
- **Markers accepted anywhere.** Every codec gets every marker, so `t.array(t.int(0, 3):newest(), 4)`, or
  `:newest()` inside an event payload, type-checks (`pipe/schema.luau`). It can only be caught by the planner.

**Fix:**
- Schema declares `:claim()` with no argument. The server attaches the verifier:
  `Net.strike:verify("hitPosition", fn)`, alongside `validate`. "A claim with no verifier is a server-view error"
  then follows naturally.
- List every codec method in one table.
- Have the planner reject markers outside a collection's top-level fields, naming the path.

### M9. Principle 3 ("never `any`, on either solver") is contradicted by §3.2

**The case:**
- **Old solver.** §3.2 accepts that runtime-path users on the old solver get silent error types: "old-solver
  users get no spurious errors". T7 shows payloads become `*error-type*`, and wrong fields go unreported.
- **New solver.** "New-solver users get exact types" is also false. The list form `t.enum({ "red", "blue" })`
  widens to `string` (T3), so `buy`'s `item` is `string` and `invoke({ item = "axe" })` passes (`pipe/client.luau`
  line 20). A union containing an enum leaks `team: string`.
- **Research.** Landscape §6.2 says "Never let payload types silently degrade to `any`. Fail loudly in docs and
  lint."

**Fix.**
- Restate principle 3 as what is true: exact on the generated path on both solvers; exact on the runtime path
  under the new solver, except list-form enums.
- Make degradation loud. The plugin and `lync check` can warn when a runtime-path project's place has
  `UseNewLuauTypeSolver` off. The `std` file can lint `Lync.server(` in strict scripts.

### M10. Principle 5 is not yet met: names standing in for definitions

Principle 5: "Every option has a name, type, unit, range, default and documented cost. Every signal has an exact
trigger." These have a name and nothing else:

| Item | Missing |
|---|---|
| `within(radius, of)`, `cooldown`, `monotonic`, `maxTotal` (§6.3) | syntax (method, option?), types, units, scope (per player? per definition?), window for `maxTotal`, and what `clamp` clamps to |
| `:input()`, `:claim(verifier)` (§6.3) | signature, verifier type, what "outcome declared only as a claim" checks |
| templates (§4.4) | any syntax at all |
| `stateRate`, `stateBudget`, `maxPendingAge`, `maxPendingFrames`, burst 4× | where they are set: neither `Lync.integrity` nor `lync.toml` has them; per-player override API |
| per-player inbound budgets (§6.1 step 2) | frames/s and bytes/s defaults, burst, per lane |
| "priority × boosts" (§5.3) | which boosts and their values (state-sync gives owner ×4, first-send ×4, distance bands) |
| jitter buffer "2–5 ticks" (§5.2) | a range in place of a default; frame or state ticks; adaptive or fixed |
| join hold "up to a cap" (§4.5) | the cap, and what happens past it |
| in-flight requests "default 16" (§5.5) | what the 17th `invoke` does: queue, `rejected`, or a throw |
| `traps = 2` (§6.5) | what the number counts, and how generated trap ids are chosen |
| `TagMismatch` "while the counter is in step" | the lookahead and `desyncAfter` rule (client-security §3.1 defines them; the design dropped them) |
| `EarlyReply` "faster than the measured round trip allows" | the bound: the brief's `earlyReplyFactor` |
| `rejectClaims`, `inboundDelay` | signatures and scope |
| "reported once per window" (§6.1 step 6) | which window |
| `Lync.group()` | its API (v4 had `add/remove/has/#/iter/destroy`) |
| `connect` | its return value and how to disconnect |

**Fix.** Each needs a row in a single options table, or cut it from milestones 1–5 (see M12).

### M11. `rate` hurts honest players, and its honest causes are incomplete

**The case:**
- **Honest clients trip it.** §6.3 claims "honest clients throttle themselves to it, so they never trip the
  server's bucket". Reliable delivery bunches arrivals: after a lost packet, Roblox's retransmission releases
  queued frames together (state-sync §1.3 puts the p99 stall at 850 ms under 5% bursty loss, and the RTO is
  unmeasured). Clients also flush a burst of held sends when `WELCOME` arrives (§4.5). With `rate = 5` and burst
  10, a 2.5 s mobile stall drops honest chat messages and raises `RateExceeded`, whose listed honest cause is
  only "a misdeclared `rate`".
- **Self-throttling is undefined.** When game code fires the sixth `chat` in a second, the design doesn't say
  whether the client drops it, queues it, or throws.
- **Low rates refuse everything.** Burst is `2 × rate`, so `rate = 0.25` gives a burst of 0.5 token, and every
  message is refused.

**Fix:**
- Burst is `max(1, 2 × rate)`, or declared.
- The client queues over-rate fires and sends them in later frames, with a stated queue cap.
- The server measures against *send* time: count by the client's frame tick rather than arrival time, which the
  tag counter already orders.
- Add "network bunching after loss" to `RateExceeded`'s honest causes.

### M12. Over-engineering: cut milestones 1–5 to a library

Principle 7 says "the library comes first", but milestones 1–5 still carry research products. Proposed lean core:

| Milestone | Keep | Defer, with reason |
|---|---|---|
| 1 Wire | bit reader and writer, fixed-width single-row codecs (§4.3's new path), length codes, quantizers, planner + IR, interpreter, golden frames | **column coder, prediction and k search** move to milestone 4. They pay only on multi-row sections, which are collections, and B3 must be settled first. Events at 60 Hz are mostly one row per definition per frame |
| 2 Events and requests | transport, frames, handshake, budgets, strict decode, `limit`, `validate`, results, observer drop events | intern table and templates (M5, B1); `timestamped` (M1) |
| 3 Compiler | shards + `.d.ts`, `lync build/check` on **Lune** | the Rust/mlua CLI (a release pipeline for three OSes is the infrastructure trap of `v5-attempt §10.3`), `watch`, `diff`, `replay`, the roblox-ts transformer (a second schema front end, against "one schema"), compiler plugins (§7.5), seeds and rotation |
| 4 Collections | reliable structure, notify for `:newest()`, audiences, catch-up, a plain budget fill | accumulators with boosts (a 40-bucket pass needs boosts defined first), `maxPendingAge`, burst windows; add them when a benchmark shows a starving record |
| 5 Integrity | direction and lane checks, `UnknownReply`, `Malformed`/`OutOfBounds` as observer events | keyed tag, rekey, replay window, permutation, traps, clock beacon, the 14-reason score with windows and caps, constraints DSL, input/claim/outcome. These are extension-grade: client-security §0.1 admits that `require(Net).def:fire()` bypasses all of them |

Each deferral leaves a seam that already exists (format version, observer, scheduler), so nothing is designed
out.

### M13. Milestones 1–2 can't be implemented from this text: undefined wire and protocol

- **Sections.**
  - The meaning of the 8 `kind:u3` values.
  - Where the definition id sits and how wide it is (and whether the per-server permutation changes its width).
  - Whether a section holds one definition or many.
  - How a run of N messages is counted.
  - The unit of `length` (bits or bytes), and whether sections are byte-aligned.
  - What `prefixVarint` is exactly.
- **Single-row encodings.** Fixed widths for the codecs that have none:
  - `t.int()` (unbounded), `t.f64` and strings in a single row;
  - `t.number`'s rounding rule (half-even? half-away?) and its interaction with "refuses out of range" at the
    edges;
  - `t.angle`'s wrap;
  - `t.rotation`'s axis-aligned flag layout;
  - `t.direction`'s exact octahedral mapping, needed for canonical decode;
  - `t.optional` inside arrays and maps (v4 forbade it).
- **The `tick` header.** Downstream: frame counter or state tick? Upstream: what is the client's `tick` when the
  ack already carries the newest server tick?
- **Handshake.**
  - Which remote carries `HELLO`/`WELCOME`, since §4.1 lists only two remotes.
  - Message formats and the hash function. It must be pure Luau, because the CLI and plugin compute it.
    `EncodingService:ComputeBufferHash` isn't available there.
  - The canonical descriptor the hash covers.
  - Where `REKEY` travels.
- **Remotes.**
  - What a "namespace group" is (§4.1). If each namespace has its own remotes, "one frame per player per lane"
    is false.
  - Remote naming and location.
  - How a client `require` finds remotes without yielding (v4's `WaitForChild` hung forever).
- **Requests.**
  - Whether `from = "server"` requests exist. §5.5's "unsolicited replies ... suspicion" and §6.4's
    `EarlyReply` imply they do; "not used: `InvokeClient`" leaves their API open. If they exist, what does the
    server's `invoke` look like: yielding, or a callback as in v4?
  - Reply encoding, including what `rejected` carries.
- **Inbound shape.** §6.1 step 1 says "exactly one buffer", but frames may carry an instance array. The instance
  array's length cap and element check must run before decode.
- **Canonical decode.** See m1.

---

## Minor

### m1. "Non-canonical encodings ... refused" is undefined for the column coder
A column has up to 4 modes × 32 k values that decode to the same values. The decoder can only refuse a
non-canonical choice by re-running the encoder's search, and then the running-mean-k fallback (§4.3) changes the
protocol. **Fix:** define canonical per primitive (minimal varints, zero padding, in-range indices, strictly
ascending map keys) and say explicitly that column mode and k are free choices.

### m2. `t.instance` drops the class type and the nil policy
`t.instance("Player")` is typed `Instance?` rather than `Player?`, and every instance field is optional. Landscape
§11 and state-sync §5.3 asked for a per-field nil policy, because streaming makes `nil` common. The policy is
either "nil allowed" or "this message is dropped, not the batch". **Fix:** `t.instance("Player")` gives `Player`
on the generated path, with `t.optional(t.instance("Player"))` for the nil-tolerant form. A required instance
that arrives `nil` drops only its message.

### m3. Codec constructor conventions disagree with §3.3's own rule
- §3.3: "Accuracy is `(min, max, step)` in the value's own unit". But `t.direction(bits)` and `t.rotation(bits)`
  take bits, and `t.angle(step)` takes radians while every Roblox angle a user reads is degrees in Studio.
- "Nothing optional changes the meaning", yet `t.f64({ nonFinite = true })` does, and it is the only constructor
  with an option table.
- Bare forms differ:
  - `t.int()` means unbounded;
  - `t.vector3()` means f32;
  - `t.string()` with no max is presumably an error.
- `t.vector3(-2048, 2048)` without a step is unspecified.

**Fix:** accuracy is always a max error in the value's unit:
- `t.direction(0.25)` means ≤ 0.25° and picks the bits; same for `t.rotation(0.45)`;
- `t.angle` takes degrees;
- non-finite floats get their own codec, `t.f64nonfinite()` or `t.float({ finite = false })`, applied
  consistently.

### m4. Smaller surface inconsistencies
- **`from` on collections.** "`from` ... required" on every definition, but the `fighters` example omits it, and
  a client-`from` collection is meaningless. Say that collections are server-only and take no `from`.
- **`audience` targets.** `audience` takes a `Lync.group()`, while `fire` takes Player, array, group, `Lync.all`
  or `Lync.except`. Use one `Target` type for both.
- **Two listening shapes.** Definitions listen with `def:connect(fn)`, collections with `def.added:connect(fn)`.
  Acceptable, but say why.
- **`Lync` isn't in scope.** The server example uses `Lync.all` after requiring only the shard, so game code
  needs two requires. The shard can re-export `all`, `except` and `group`.

### m5. Client reads allocate per change, and `changed` can fire twice per tick
- `get` returns "a frozen snapshot", and `changed` passes `(id, fighter, previous)`. With copy-on-write, every
  `:newest()` update allocates a new record plus `previous` on an interpreted mobile client: 100 records at 20 Hz
  is 4000 tables/s.
- When a record's reliable and `:newest()` fields both change in one tick, they arrive on different lanes, and
  `changed` fires twice (v4 defect, state-sync §5.3 item 4). The design doesn't address it.

**Fix:**
- Type the client record as `read` fields and pass the live record. Provide `previous` only as the changed field
  names, or behind an opt-in.
- Document the two-lane split, and consider state-sync's `:atomic()`.

### m6. Server Authority is absent
Landscape §2.4/§6.19, state-sync §8.1 and anticheat §3.2 all say that under Server Authority, client→server
simulation input goes through InputActions, and remotes are off the simulation timeline. The design never
mentions it. M4's implicit input streams compete with it directly. **Fix:** a paragraph that says what Lync
carries in Server Authority games (intents, claims, non-simulation state) and exposes its tick for bridging.

### m7. A record's owner is never declared
`:owner()` boosts the owner's priority, but no option says who owns a record. **Fix:** a collection option such
as `owner = "key"` (the key is a `UserId`), or a server-side `Net.fighters:owner(id, player)`.

### m8. Research items dropped without a word
- **Unreliable-event deadline.** The 1 s deadline for unsent unreliable events (state-sync implication 1) is
  gone.
- **`:initial()`.** State-sync's core list has it (sent on add only); the design doesn't.
- **Handler order.** Payload-first handlers were on the attempt's keep list (`v5-attempt §11`). Player-first is
  a defensible change (it matches `OnServerEvent`), but say that it overrides the brief.
- **Placement.** Client-security-build §2.1 puts the client shard in a replicated folder and the server shard in
  ServerScriptService. That is consistent with the design.

**Fix:** add a "deliberately dropped" list with one reason each.

### m9. Hot-path bytes and CPU that could be per frame or zero
- **Upstream unreliable header.** `tick` (2 B) + ack (6 B) + sequence and tag (3.5 B) is 11.5 B before any
  section, on top of about 14 B of engine overhead, to carry a few bytes of input. The upstream `tick` is
  redundant with the ack.
- **Upstream reliable header.** It also repeats the 6 B ack, which only matters for unreliable downstream state.
  Send the ack on the unreliable lane plus the 10 Hz heartbeat.
- **Downstream reliable header.** `tick:u16` on every frame costs 120 B/s per player at 60 Hz. A 1-bit
  "tick changed" flag plus the tick only on state ticks saves most of it.
- **`FireAllClients`.** "When every recipient's frame is identical" should be decided structurally (no
  per-player content this flush), not by comparing 100 buffers.
- **`Lync.except(group)`.** It resolves per message at flush. Resolve each distinct target once per flush.

### m10. `t.union` discriminant and a variant field called `kind`
The discriminant is hard-wired to `kind`. A variant record with its own `kind` field has no specified behaviour.
**Fix:** the planner rejects it with the definition path.

### m11. Open questions that are actually blocking proofs
§11 lists "readability of side-split type errors" as a proof before milestone 3. T6 and `pipe/server.luau`
line 19 already answer it for the runtime path: the message is a cyclic expansion
(`Key 'fire' not found in table '{ connect: t1, validate: ... } where t1 = ...'`). It names no side and no
definition. §3.5's quoted message ("key `invoke` not found in `ServerRequest<...>`") is aspirational. Mark it so.

---

## Taste (capped at five)

1. **`validate` uses `nil` for success.** `return nil` means accept and a string means reject. Every other
   predicate in Luau is truthy for success. Propose `return true` / `return false, "blank"`.
2. **One delivery option.** Events could take a single `delivery = "reliable" | "unreliable" | "newest"` in place
   of `lane` plus `newest`, mirroring Blink's `Type: Reliable`. That removes an unspecified combination
   (`newest = true` on the reliable lane).
3. **`Lync.schema("arena", ...)`.** The `[[namespace]]` in `lync.toml` and the undefined "namespace group" (§4.1)
   are three names for one thing. Use "namespace" everywhere and drop "group".
4. **`key = t.int()`** spends Exp-Golomb bits on `UserId` keys (about 40 bits). `t.int(1, 2^53)` is no better.
   Records are referenced by slot after the add, so say that keys travel once. (State-sync §5.3 item 2 has
   slot + generation; the design never mentions slots.)

---

## What is genuinely good (keep through revision)

- **Option-table definitions.** They read like Blink's `event { From, Type, Data }` but are live Luau. With the
  `D & { from: ... }` signature, the runtime path infers exact handlers, rejects wrong-side calls and wrong
  variants, and rejects an extra handler parameter (`pipe/`).
- **Results.** The `{ ok, value } | { ok, error }` result narrows correctly on **both** solvers, generated
  shapes (`r4`) and through type functions (`pipe/client.luau`). Discriminated `kind` unions narrow on both
  solvers too.
- **Single-row fixed-width coding (§4.3 edit)** removes the per-column header tax from events.
- **§5.1.** It is honest about late sends: no `start()`, an idempotent optional `flush()`, and `BindToClose`
  handled.
- **One planner, seed 0 canonical, concrete generated types for the old solver.** This is the right answer to
  the solver split.
- **The security stance.** Budgets before decode, direction and lane in the hash, never kick, and §6.4's
  per-reason triggers with honest causes. That table is the right shape; extend it per M11.
- **`collection`**, no audience-by-field, and one `rate` concept are good settlements. M3 only asks for the
  outbound one to get a different word.

---

## Probe index (`.data/docs/probes/review-1/`)

All runs use luau-analyze 0.740 with `--solver=new` unless noted.

| File | Tests | Result |
|---|---|---|
| `r1_from_literal.luau` | literal option values passed to `<D>(def: D)` | `from` → `string`, `timestamped` → `boolean` |
| `r2_from_workarounds.luau` | generic field, overloads, `D & { from: union }` | the intersection and the generic field keep `"client"`; overloads select by literal and reject typos |
| `r3_patch_in_view.luau` | T4b generic `patch` inside a side-selected view | works directly; collapses the whole view through `SelectSide` |
| `r4_generated_shapes.luau` | concrete shard types, **new and old solver** | result and union narrowing work on both; `{ healht = 90 }` accepted on both |
| `r5_option_signatures.luau` | full option tables against several signatures | only `from` stays exact; a fully typed option intersection gives spurious errors; option typos accepted |
| `r6_request_isolate.luau`, `r7_intersection_return.luau` | isolating the request error | clean in isolation |
| `pipe/` (`lync.luau`, `schema.luau`, `server.luau`, `client.luau`, `buyonly.luau`) | the §3.4–§3.6 surface end to end across `require` | exact handlers and side split; enum widening; markers accepted anywhere; spurious request error in `buyonly.luau` |

Run: `cd .data/docs/probes/review-1 && ~/.cache/luau-skill/luau-0.740-linux-x86_64/luau-analyze --solver=new <file>`
(for `pipe/`, run from inside `pipe/`).
