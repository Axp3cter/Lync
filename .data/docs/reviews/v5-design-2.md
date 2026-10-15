# Review of the v5 design, draft 2

**Scope.**
- Reviewed: `.data/docs/design/v5.md` draft 2 (1316 lines), against its change log `v5-changes.md` and the
  author's three final decisions:
  - facts, not verdicts;
  - client-side integrity is first-class, judged by the tamper cost it imposes against its own costs;
  - rotation and permutation stay.
- Not re-argued: those decisions.
- Evidence: the research briefs; probes `typing-and-codegen`, `review-1`, `review-redundancy` and `design-2`; and
  new probes in `probes/review-2/` (index at the end).
- Tools: luau-analyze 0.740 (new solver unless stated), luau-lsp 1.70.1 and the Luau 0.740 VM, all through the
  luau skill's pinned toolchain.

**Count:** 3 blocking, 12 major, 11 minor, 2 taste.

**Draft-1 findings marked fixed but not fixed, or fixed with a new problem:**

| Draft-1 finding | Status in draft 2 | Finding here |
|---|---|---|
| M13 (milestone 1–2 wire gaps), "accepted" | not done: bit order, padding points and nested-column flattening are still undefined | B2 |
| B2 | fixed; but reliable fields now replicate every flush with no budget and no rate knob | M5 |
| B3 | fixed by measurement; but newest-wins on a 12-bit sequence freezes idle records | M2 |
| M7 | fixed; but the delta-coded tick header conflicts with `FireAllClients` | B3 |
| M9 | "degradation is loud" can't be built | M11 |
| M11 | fixed; but the client FIFO breaks call order | M12 |
| m9 | fixed; but per-namespace frames multiply calls | M1 |
| M1 | the request signature error is resolved by draft 2's own change, though the runtime-path view crashes the analyzer on any schema typo; this predates draft 2 and review-1 missed it | M3 |

The rest of review-1 is fixed as logged.

---

## Blocking

### B1. Dropped asks leak request slots forever, so "every ask is answered" is false

**The case.** §5.6 says an ask's slot "is released only by its answer, or when the player leaves". An asking-side
timeout "keeps the slot". §6.1 drops asks without answering them in six places:

| Step | What drops the ask | Honest cause listed in §6.3 |
|---|---|---|
| 2 | `overBudget` drops the whole frame | a stall longer than the burst |
| 3 | `tagMismatch` drops the frame | — |
| 4 | `malformed` refuses the frame | — |
| 5 | `trap`: the definition has no handler | — |
| 5 | `unknownEnum` drops the message | engine version skew |
| 5 | `instanceMissing` / `instanceClass` drop the message | streaming; replaced instance |

Only `limit` and `validate` answer `rejected`. Example:
1. An honest mobile client comes out of a 3 s stall.
2. Its 180 bunched reliable frames, at about 400 B each, exceed the 65,536 B byte burst.
3. `overBudget` drops the frames that held its asks.
4. Each lost ask holds a slot forever.

After 16 such losses, every later `invoke` on that connection "waits on the asking side" until it times out,
until the player rejoins. The same happens to the server's 16 slots for asks to a client when the client's
answer frame is dropped by `overBudget`.

**Fix.**
- Answer every ask that is dropped after its slot has been read: `rejected` for `trap`, `unknownEnum` and
  `instance*`. That costs one answer row.
- For frame-level drops (steps 2–4), where the server never reads the slot, let the asking side reclaim a slot on
  timeout. Make reuse safe with a 1-bit slot epoch carried in the ask and echoed in the answer. A late answer whose
  epoch doesn't match is then exactly `unknownReply`.

### B2. Milestone 1 still can't be built from the text

The change log marks review-1 M13 "accepted". These are still undefined or wrong:
1. **Bit and byte order.** Nothing says whether the bit writer is LSB-first or MSB-first, or the byte order of
   `u16`, `f32` and `f64`. (`grep -i 'lsb\|endian'` finds nothing.) Golden frames can't be written before this.
2. **Padding points.** §4.1 says every shared state section and event run starts "on a byte boundary with zero
   padding". The grammar (`run := id count−1:EG0 rows`) has no padding element. Nothing says whether upstream runs,
   the per-list counts or the header are padded either. Rule 4 ("non-zero padding bits") can't be checked until
   the grammar says where padding is.
3. **Nested types in columns.** §4.3 codes "one column per field", but records hold nested records,
   `t.optional`, `t.union`, arrays and strings. How do `title = t.optional(t.string(16))` (presence column, length
   column, tail bytes?) or an array-of-unions field flatten into columns, and in what order? Milestone 1 builds
   column-coded arrays, so this is in scope.
4. **Rule 2 is off by one.** "Any count, length or index at or past its maximum" refuses a 200-byte
   `t.string(200)` and a `maxCount`-element array, which §3.3 encodes as legal (`⌈log2(maxCount + 1)⌉` bits).
5. **`t.int()` isn't exact to 2^53** (`review-2/n1_numeric_edges.luau`). The zigzag of a negative value is
   `−2v − 1`, which is odd and above 2^53 once |v| > 2^52, so doubles round it. The probe gets −(2^52 + 1) back as
   +2^52, and −(2^53 − 1) back as 2^53 − 2. **Fix:** cap at |v| ≤ 2^52, or code the sign bit and EG-0 of the
   magnitude.
6. **`t.number` refuses honest values at the top of the range** (same probe). `steps = ⌊(max − min)/step⌋` uses
   floats, so `t.number(0, 0.3, 0.1)` gets 2 steps, while `v = 0.3`, or any v ≥ 0.25, rounds to q = 3. The encoder
   emits it, and the decoder refuses the whole frame under rule 3. `(0, 0.7, 0.1)` and `(0, 2.3, 0.1)` fail the
   same way. **Fix:** compute `steps` once at declaration as `round(r)` when |r − round(r)| < 1e-9, otherwise
   `⌊r⌋`. Clamp q to `steps` on encode.
7. **Codec details missing from §3.3:**
   - `t.angle`'s bit width (⌈log2 n⌉ is implied but not stated);
   - `t.map`'s count width;
   - whether `t.direction` normalises or refuses a non-unit input;
   - when `t.rotation` must use the axis-aligned form, and with what tolerance (canonical or free);
   - whether a `t.rotation` input with a non-zero position is refused.
8. **The schema hash input is undefined.** "The IR's canonical serialization" needs its byte layout:
   - how the floats `min`, `max` and `step` are serialized;
   - which options are folded in (`limit`? `timeout`? `priority`? `maxRecords`?);
   - the `t.custom` name and version encoding.

   The CLI, the plugin and the runtime must agree on it bit for bit.

**Why blocking.** Golden frames, the canonical decoder and the hash are milestone 1's deliverables, and each item
above changes the bytes.

### B3. Encode-once chunks conflict with fields that differ per frame

§4.1: "each partition's state section and each event run is encoded once per flush … assembled with
`buffer.copy`", and one frame can go to everyone through `FireAllClients`. Three per-frame encodings break this:
1. **Instance indices.** §3.3: an index is ⌈log2(arrayLength)⌉ bits "into the frame's instance array".
   - Run A, broadcast with one instance, goes to P1 and P2.
   - P1 also gets run B, targeted, with two instances.
   - P1's array has 3 entries (2-bit indices); P2's has 1 entry (0-bit indices).
   - Run A's bits therefore differ per player and can't be a shared chunk.

   **Fix:** run-local instance indices and widths, with the frame's array being the concatenation of run arrays
   in run order.
2. **The tick header** (`'0'` same as the previous reliable frame | `'10'` +1 | `'11'` u16) is relative to each
   client's previous reliable frame. Players who got a targeted frame last flush and players who didn't need
   different headers, so one `FireAllClients` buffer can't serve both. **Fix:** a shared frame always uses
   `'11'`, or define the delta against the previous flush's tick, which every connected client sees.
3. **Strings in shared chunks.** Strings sit in a tail written backwards from the frame's end. A shared chunk
   must carry its tail bytes separately, stored reversed, and they land at a position that depends on the frame.
   It's workable, but unspecified.

Unreliable frames carry a per-player 12-bit sequence, so they can never be shared through `FireAllClients`. Say
so, since §4.1's sentence reads as both lanes.

---

## Major

### M1. High-frame-rate clients trip the inbound budget, and per-namespace remotes multiply calls

**Clients flush every frame.** §5.1 flushes once per frame at `PostSimulation` on both sides. Roblox's Maximum
Framerate setting allows up to 240 FPS ([announcement](https://devforum.roblox.com/t/introducing-the-maximum-framerate-setting/2995965);
a staff reply says RunService events fire at that rate,
[thread](https://devforum.roblox.com/t/allow-fps-related-fast-flags/3971185)). A client that fires an aim event
every frame at 144 FPS sends 144 reliable frames/s, against the default `inbound.reliable.frames` of 120/s with a
burst of 240. Its frames are dropped as `overBudget` within 3 s. The design's justification, "an honest client
sends one reliable frame per flush (60/s)", assumes a 60 Hz client, and high frame rate is missing from the
honest causes.

**Calls multiply by namespace.** §4.1 also sends one frame "per flush, per player, per namespace", each on that
namespace's own remotes. A game with 5 namespaces at 60 Hz makes 300 reliable calls/s per client, at about 11–14 B
of engine overhead each, against Roblox's documented ~500 calls/s per client per remote type, which the game's
own remotes share. State-sync §8.3 concluded "Lync sends at most one call per lane per frame … so it fits".
Per-namespace frames undo that, and landscape §2.1 says one call per player per frame is optimal.

**Fix.**
- The client flushes at most every 1/60 s: accumulate dt, flush when due. It saves bytes too.
- Use one remote pair per connection and carry the namespace in the id space: one global id table, or a namespace
  prefix per run. The tag counter is already per connection.

### M2. Newest-wins on a 12-bit sequence freezes records that sat idle

**The case.** §5.3: "the client applies a record's row only if its frame seq is newer (12-bit serial
arithmetic)". Downstream unreliable frames run at 20–60/s plus splits, so 2048 frames pass in about 34–102 s.
1. A record stops moving, and the client stores the sequence S of its last row.
2. It moves again 60 s later. The new row's sequence compares as *older* than S, so it is dropped.
3. The ack still covers the frame, so notify never resends.
4. Every following row also compares older, until the sequence passes the other half of the cycle. The record
   stays frozen for up to another ~34–102 s.

**Fix.** Order rows by the frame header's `tick:16`: 54 minutes of range at 20 Hz. A repair is always sent at a
later state tick, and the frames split within one tick carry disjoint rows. Alternatively, expire stored
sequences older than 2048 frames.

### M3. Any schema typo segfaults the analyzer and luau-lsp on the runtime path (new solver)

**The case.**
- `review-2/pipe/server_typo.luau` requires a schema with one misspelled constructor (`reply = t.bol()`) through
  `Lync.server(...)`.
- luau-analyze 0.740 exits with a segmentation fault (code 139), and luau-lsp 1.70.1 `analyze` does the same.
- It reproduces with a typo in an event's `data`, a nested record field, and a collection field
  (`pipe/min_schema.luau`), and with review-1's draft-1 stand-in unchanged (`crash_r1lib/`). It is a property of
  the type-function view, not new in draft 2.
- Requiring the same schema without the view reports the typo normally (`crash_r1lib/min_server_noview.luau`).

**Cause and fix.** The stand-in's `Infer` calls `error()` on a non-codec, and that error type flowing into the
side-selecting type function in another module crashes the solver. With `Infer` returning a marker type instead
of calling `error()`, the crash is gone and the user sees only "Key 'strng' not found in table 't'"
(`crash_fix/`).

**Why it matters.** In VS Code a crashing language server takes every script's diagnostics with it, on each
keystroke that leaves the schema mid-edit. **Fix:** a rule for the types module: no type function calls `error()`
on input derived from user values. It returns a marker type such as `"[Lync] expected a codec at chat.data"`. Add a
typo schema to the milestone 1 typing proofs.

### M4. Decoys are visible on the wire and draw on shared slots

**On the wire.** §6.2.11 says "nothing marks a decoy on the wire or on the client". But decoy "adds, updates and
removes" travel "into that viewer's own sections only". Real records get updates in the shared partition section
and appear in a viewer-own section only for catch-up. A decoy keeps getting reliable updates in a viewer-own
section, flush after flush. A patched client that logs which section each slot's updates came from separates
decoys from real records exactly, with no game knowledge. This is per-build work at most, which is the cost the
author's rule asks to be stated.

**Slots.** Decoys take "slots from the same allocator" as real records, and slots are shared across viewers for
encode-once. Nothing says:
- whether decoys of different viewers may share a slot;
- what happens when a real `set` needs a slot a decoy holds;
- how `maxPerViewer` × viewers counts against `maxRecords` (100 viewers × 1 decoy against a default of 1024, or
  a declared 64);
- what happens when a decoy's key later becomes a real record's key (only "equal to a live record's key" is a
  caller error).

**Fix.**
- Decoy reliable updates ride in the viewer's copy of the partition section, re-encoded for that viewer while it
  has decoys, so placement doesn't mark them. Or restrict decoys to `:newest()` fields, whose rows are per-viewer
  anyway, and state the remaining tell.
- Define decoy slots as per-viewer slots outside the shared range.

### M5. Reliable fields now replicate every flush with no budget and no rate knob (side effect of the B2 fix)

**The case.** §5.1: reliable field changes go "every flush … never deferred by the budget". §5.4 budgets only
`:newest()` rows, and `:maxHz` moved to `interest`. A reliable field written every frame (a progress timer, ammo,
a cooldown display) now replicates at 60 Hz with nothing in the core to slow it. In draft 1 it went at 20 Hz.
`stateBudget` ("ceiling on bytes per player") doesn't bound it. The tycoon model (≈160 records, ≈60% changing per
tick) pays its section headers and k search 60 times a second instead of 10–20.

**Fix.**
- Document that reliable fields are sent as often as they're written.
- Add a core collection option `reliableHz` (a divisor of 60) that coalesces reliable *field* updates while
  structure stays per flush. The order guarantee is then exact for structure, and for fields at their rate.

### M6. `Lync.configure` brings back start-order rules

**The case.** §6.4: "options carried in `WELCOME` are fixed once the first `WELCOME` is sent, and changing them
later throws". In Studio Play Solo, the client's `HELLO` can be answered before the server Script that calls
`Lync.configure` runs, because Script start order is undefined. `configure({ stateRate = 30 })` then throws, and
only in some runs. This is the v4 start-order pain review-1 and §5.1 set out to remove. Build brief §5.3 had the
safe rule: "A change after the first player is admitted applies to new connections only".

**Fix.** Either adopt the brief's rule (per-connection options apply to later connections; `stateRate` and
`permuteIds`, which must be server-wide, are fixed at first use and documented), or delay `WELCOME` until the
first `PostSimulation` after the first view use.

### M7. The clock beacon's parameters exclude each other

**The case** (§6.2.9):
- An arrival gap over 2 s restarts the estimate.
- `clockBeacon`'s allowed range is 0.5–10 s.
- Any `clockBeacon` ≥ 2 s produces 2 s gaps by itself, so every beacon restarts the estimate, and `clockRate`
  can never be reported.
- Minima are taken per 5 s window, so `clockBeacon` > 5 leaves windows empty.

**Fix.**
- Range 0.5–1.5 s, or a restart gap of `max(2, 3 × clockBeacon)` with windows of `max(5, 2 × clockBeacon)`.
- State the Theil–Sen cost at the top of `clockWindow`'s range: 120 points is 7,140 slopes per fit, not the
  stated "12-point fit".

### M8. Milestone 2 gaps: handshake, join and protocol facts

1. **Joining players and `FireAllClients`.** Before `WELCOME` a client has no permutation seed and can't decode.
   §4.1 decides `FireAllClients` "from the targets" but doesn't exclude pre-`WELCOME` players. If they're
   included, their decoder refuses those frames and counts them as `clientRefusedFrame`, whose listed honest cause
   is only "a Lync bug". If they're excluded, events to `Lync.all` during a join are silently lost for that
   player, and that should be documented (v4 dropped them and said so).
2. **`MISMATCH` on the server.**
   - What happens to server sends for that player and namespace?
   - No anomaly reason exists for a hash, seed or version mismatch, which is a fact the server observes (a forged
     or stale build).
   - No reason exists for data before `HELLO`, a control message in the wrong direction or at the wrong time, or a
     `BEACON` while `clockBeacon = 0`.
   - `repeatedHello` is the only control-misuse reason.
3. **Untagged `HELLO` and the counter.** Every namespace's first frame is untagged. Does it advance the
   connection-wide counter? How does the server tell an untagged `HELLO` frame from a tagged one, other than by
   "first frame on this remote"?
4. **Tag across milestones.** Milestone 2 ships frames and the handshake, but the tag is milestone 5. Say whether
   milestone 2's frames reserve the 16 bits or whether milestone 5 bumps the protocol version.
5. **Request edge cases.**
   - An `answer` whose slot is in flight but whose id isn't that ask's answer id.
   - An `ask` on a slot that is already in flight on the answering side.
   - A server `invoke(player, …)` before that player's `WELCOME`.

   None of these has a defined result or reason.
6. **Frame-size rule.** No §4.6 rule refuses an upstream reliable frame over 16,384 B. Honest clients never send
   one, but the byte burst admits it.
7. **Observer scope.** The `frame` observer event has no field list (principle 5), and milestone 2 ships "the
   milestone's `anomaly` reasons" without saying which.
8. **Coalescing.** A coalesced event's `evidence` is undefined: the first occurrence's, the last's, or a
   reduction. So is whether the window is per key or global.

### M9. Facts-not-verdicts: wording that still judges

- **§0 and §6 intro.** "Turn tampering into facts" and "turns tampering into facts" state that the facts *are*
  tampering. Write "reports what it observed".
- **§6.2.5.** It cites "a very high-confidence signal". That is a confidence label of the kind §6.3 abolishes, even
  as a quotation. Drop it.
- **Evidence names.** `elevated` and `foreign` in `REPORT` and the evidence are characterisations. Name what was
  measured: `identityProbeSucceeded` and `sourceNotListed`.
- **Action words.** The action column uses "dropped" for `overBudget` and `tagMismatch` but "refused" for
  `malformed` and `wrongDirection`. If the effect is the same, use one word. If it differs, define the difference.
- **"Lync never tells the client what was observed" (§6.2).** This is contradicted by:
  - `REKEY`, which tells a forging client that its tags failed;
  - `rejected` answers for `limit`.

  Both are fine as protocol, but the sentence should say "beyond `REKEY` and request outcomes".

### M10. Leanness: about 250 lines that don't change what gets built

- **Rationale, not specification** (about 150 lines in §6.2):
  - the route table (A0–A8);
  - "How each measure is judged", which restates the author's rule;
  - the twelve "Protects" and "Tamper cost" paragraphs.

  These are the case for each measure. They belong in a client-integrity rationale doc, or in `v5-changes.md`
  where the rule is already applied measure by measure. The core needs each measure's mechanism, wire, options
  table, anomaly reason and cost.
- **Duplicates of the change log:**
  - §6.2.13 (refused measures, 20 lines) repeats `v5-changes.md`'s re-evaluation table;
  - §12 (23 lines) repeats its "Deferred" list.

  Keep one line pointing there.
- **History in the design** (28 citations of drafts and reviews):
  - "Draft 1's silent fallback is gone" (§3.2);
  - draft 1's `kind:u3 length` (§4.1);
  - "Sizes … against draft 1's layout" (§4.1);
  - the draft-1 problem statement in §5.1;
  - "Draft 1's `onReceive`" (§7.1).

  These describe the change, not the design.
- **Said three times:**
  - the `Lync.request` signature and side-split proofs (§3.2, §10, §11);
  - `REPORT` (§4.4, §6.2.7, §6.2.8);
  - the `WELCOME` integrity fields (§4.4 and each measure).
- **Extension-doc candidate.** §6.2.9–§6.2.12 (beacon, early answers, decoys, canaries) are complete subsystems.
  Specifying them in an integrity doc, with the core keeping their wire, options and reasons, would bring the core
  back near 1,000 lines without dropping any decision.

### M11. "Degradation is loud" can't be built as specified (review-1 M9 fix)

- **The plugin can't read the property.** `Workspace.UseNewLuauTypeSolver` is `NotScriptable` (API dump 0.741),
  so the plugin can't check it.
- **`lync check` usually can't either.** It can see the property only when a Rojo project file sets it, or by
  reading a place file.
- **selene can't scope the lint.** Its `std` files declare globals and their signatures; they have no rule that
  depends on a script's `--!strict` mode. Flagging `Lync.server(` "in `--!strict` scripts" is beyond them. I
  haven't seen a selene mode-aware option, so verify before relying on it.

**Fix.**
- `lync check` warns on every runtime-path use, unless the project declares `typeSolver = "new"` in `lync.toml`.
- The runtime prints one Studio line on first `Lync.server`/`Lync.client` use, stating the path's typing
  limits.

### M12. The client's `limit` FIFO reorders messages across definitions

**The case.** §6.1: the client "holding over-limit fires in a FIFO … sends them as the bucket refills".
1. Game code fires `chat` a sixth time, then fires `equip`.
2. `equip` leaves this flush.
3. The held `chat` leaves up to 200 ms later.

On the reliable lane, call order across definitions was a guarantee: draft 1 §5.1, and §4.1's "frames of several
namespaces keep call order". An over-limit `invoke` also waits in the FIFO with its `timeout` running.

**Fix.** Either hold every later reliable message behind a held one (strict order, head-of-line delay), or
document that `limit` makes delivery order per definition only.

---

## Minor

### m1. "The build seed changes exactly two things" (§3.2) contradicts §3.1
§3.1 says record fields *and union variants* are ordered by name at seed 0, and "a nonzero build seed permutes
that order". §6.2.4 permutes only "each record's field order". Decide whether variant indices rotate. If they do,
§3.2's count is three.

### m2. `t.enum(Enum.Material)` is `Codec<unknown>` on the runtime path
§3.3 types it as `Enum.Material`, and §3.2 lists only list-form enums as widening. Structural inference through
`GetEnumItems` gives `Codec<unknown>` (`review-2/t2_enum_roblox.luau`, `check --roblox`, luau-lsp 1.70.1). Add it
to §3.2's exceptions.

### m3. Canary matching and collisions
- "Looked up among the canary values": exact equality or substring? A canary pasted into chat with other text
  escapes an exact match.
- `min(16, maxBytes)` gives a 4-character canary for `t.string(4)` (62^4 ≈ 1.5 × 10^7 values), which an honest
  4-character input can hit. Add that to the honest causes, or require `maxBytes` ≥ 12.

### m4. `maxRecords` against the 2 s slot quarantine
Freed slots wait 2 s. A collection with 64 slots that spawns and removes 40 records/s needs about 80.
- Is `maxRecords` the live-record cap or the slot count?
- What does `set` do when no slot is free: throw at the caller, or queue?

### m5. The permutation's "per-build work" is unsupported
§6.2.3 says "on the generated path the table lives in the client shard, so locating it is per-build work". The
table is drawn per server at run time, and it is an array holding a permutation of 1…count. A `getgc` search for
that shape is the same in every build. State the tamper cost as "per session: read the seed or table", which is
true and is the author's criterion.

### m6. Two naming conventions in `Lync.configure`
- Grouped tables: `callerProbe.share`, `observe.window`, `inbound.reliable.frames`.
- Flat prefixes for the same kind of grouping: `tagCover`, `tagLookahead`, `clockWindow`, `clockConfirm`,
  `clockRateLimit`.

Principle 4 says use one. Proposal: `tag = { cover, lookahead, desyncAfter, rekeyInterval }` and
`clock = { beacon, rateLimit, window, confirm }`.

### m7. Reachability's notion of "escape"
- **The definition rules out common usage.** "Passing it as a value, storing or returning it" covers the usual
  patterns: `return Net` from a client module, `self.Net = Net` in a controller, dependency injection. So most
  structured games will be "incomplete", and §6.2.6 does nothing for them except a line in the report.
- **"Storing" needs a definition.** Is `local Net = require(...)` storing? It must not be.
- **roblox-ts projects are unspecified.** Their compiled output reaches views through `TS.import`.

### m8. Downstream reliable frames have no size cap
Catch-up for 1024 records is tens of KB in one `FireClient`. Whether the engine has a reliable payload limit is
unverified (the attempt assumed 16,384 B). Add it to §11.

### m9. The milestone 5 tag specification is incomplete
- The PRF input layout: count width and byte order, length, instance count.
- Which 16 of HalfSipHash's output bits are kept.
- Whether the cover includes the header.
- That the server keeps verifying with the old key until `REKEY-ACK` arrives.

### m10. Integrity declarations take unchecked strings
`Net.strike:refers("tagret", "fihgters")` and `Net.fighters:canary("titel")` type-check
(`review-2/pipe/server.luau`). The design doesn't say they throw at the caller on an unknown field or collection.
Say so: they are caller errors with the path.

### m11. Unreliable `limit` and `holdFull` semantics
- Unreliable fires before `WELCOME` are "dropped" silently: no anomaly, unlike `holdFull`.
- An over-limit *unreliable* fire is queued like a reliable one, which contradicts "unreliable means exactly
  that".

---

## Taste

1. **Two meanings of `kind`.** Observer events use `kind = "frame" | "anomaly"`, and union payloads use `kind`
   as their discriminant. A game that observes and also has a union named `frame` reads oddly. Consider
   `type = ...` for observer events.
2. **`callerProbe.share`.** "Share" reads as a portion of something owned. `sampleRate` is the usual word.

---

## Typing claims re-run (draft 2's changed surface)

**`pipe/`** is a stand-in for draft 2's §3.4–§3.5 surface across `require`. Confirmed:
- `validate` must return `boolean`: `return nil` is rejected.
- A singleton collection takes no key: `Net.round:set(1, …)` is rejected, and `get()` is typed.
- `Requests go both ways`: server `invoke(player, data)` is typed, and calling it without the player is rejected.
  The client `handle` is typed.
- `connect` returns a connection with `disconnect`.
- Server-view integrity methods don't disturb the view.

**Review-1's spurious `Lync.request` error is gone** once `RequestDef` depends on `from`, as draft 2 needs anyway
for two-way requests (`pipe/schema.luau` is clean). That settles §3.2's first milestone 1 proof in the stand-in.

**`t.convert(base, decode, encode)` (`t1_convert.luau`).**
- Lambdas infer with no annotations.
- `U` comes from `decode`'s return, both for a leaf codec and for a record base through `Infer<S>`.
- A misspelled field in `decode` is rejected.

The attempt needed annotations here.

**Observer events (`t3_observer.luau`)** narrow on `kind`, then `reason`, and `evidence` narrows per reason, on
**both** solvers.

**Not as claimed:**
- the runtime-path crash (M3);
- `t.enum(Enum.Material)` (m2);
- integrity-declaration strings (m10).

---

## What is genuinely good

- **Frame refusal.** Refusing whole frames and writing the tail backwards is the right answer to review-1 B1: no
  lengths, no skip machinery, 1 bit per empty list.
- **Decisions from measurement.** `:newest()` coding (§5.3) was decided from a measured table with the cost
  stated (13 Hz effective on a 100-player shooter), not by assertion.
- **Explicit request slots.** Making slots explicit, with the stated reason that the two ends free them at
  different times, is exactly right. B1 asks only that every path gives the slot back.
- **Anomaly reasons.** The §6.3 table (exact trigger, action, evidence, honest causes) is the right shape for
  facts, not verdicts.
- **Configuration.** The §6.4 options table finally gives every knob a type, range, default and cost.
- **Typing.** The draft-2 surface (`t.convert`, singleton collections, two-way requests) holds up under the type
  probes, and `D & { from: … }` with a `from`-dependent return type is now clean.

---

## Probe index (`.data/docs/probes/review-2/`)

| File | Tests | Result |
|---|---|---|
| `n1_numeric_edges.luau` (run on the VM) | `t.int()` zigzag near 2^53; `t.number` step count against q at the top of the range | negative values with \|v\| > 2^52 don't round-trip; `(0, 0.3, 0.1)`, `(0, 0.7, 0.1)` and `(0, 2.3, 0.1)` put q(max) past the last step |
| `pipe/` (`lync.luau`, `schema.luau`, `server.luau`, `client.luau`) | the draft-2 API surface end to end, new solver | as in "Typing claims re-run" |
| `pipe/server_typo.luau`, `client_typo.luau`, `schema_typo.luau`, `min_schema.luau`, `min_server.luau` | one misspelled codec constructor | luau-analyze 0.740 and luau-lsp 1.70.1 segfault (exit 139) |
| `crash_r1lib/` | the same typo with review-1's unchanged stand-in, with and without the view | crashes only through the view |
| `crash_fix/` | `Infer` returning a marker type instead of `error()` | no crash; a normal diagnostic |
| `t1_convert.luau` | `t.convert` inference | infers both ways, typo rejected |
| `t2_enum_roblox.luau` (`check --roblox`) | `t.enum(Enum.Material)` through `GetEnumItems` | `Codec<unknown>` |
| `t3_observer.luau` (new and old solver) | anomaly union narrowing | narrows on both |

Run `.luau` type probes with `~/.cache/luau-skill/luau-0.740-linux-x86_64/luau-analyze --solver=new <file>` from
the file's own directory. Run `n1` with `.../luau n1_numeric_edges.luau`.
