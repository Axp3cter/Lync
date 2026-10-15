# Lync v5 design: changes from draft 1 to draft 2

2026-10-15. Applies `.data/docs/reviews/v5-design-1.md` (review-1: B, M, m, T ids) and
`.data/docs/reviews/v5-design-1-redundancy.md` (redundancy: R1–R20) to `.data/docs/design/v5.md`, under the
author's decisions. Section numbers refer to draft 2.

**Count:** 51 findings. Accepted 30, changed 20, rejected 0, deferred (author to decide) 1. Some changed findings
had parts rejected (M11, M12, m3, m4, m5, R6) or deferred (M12, R17); each row says which.

## Overlaps resolved once

| Overlap | Findings | Resolution |
|---|---|---|
| Section skipping against the shared string tail | B1, R6 | No section lengths and no skipping: a malformed frame is refused whole, the tail is written backwards from the end, and per-list counts replace `kind`/`length` (§4.1, §6.1 step 4). R6's fix, not B1's per-section tail spans: skipping buys an honest client nothing, since a malformed upstream frame that passed the tag is a bug or an attacker, and the downstream client never skips. |
| `:newest()` sent absolute against column-predicted | B3, R3 | Measured (`probes/design-2/newest_layout.out`): absolute rows encoded once per tick, copied as byte-aligned chunks, no prediction and no column coding (§5.3). Prediction against acked baselines (2.3–2.8x fewer bytes on shooters) is the `acked` extension. The column coder serves only multi-row reliable sections, arrays and runs (§4.3). |
| Header and ack redundancy | m9, R5 (with M7, R1) | Upstream tick deleted; ack is a 12-bit downstream unreliable sequence plus a 16-bit bitfield, sent once per flush only when new, behind a presence bit; downstream reliable tick delta-coded; heartbeat replaced by an ack-only unreliable frame when one is owed (§4.1). 886 → 353 B/s up, 353 → 130 B/s down for a busy player. |

## Review-1 (`v5-design-1.md`)

| Id | Title | Outcome | Reason |
|---|---|---|---|
| B1 | Skippable sections can't coexist with a shared byte tail, the intern table, or rate-before-decode | changed | Resolved with R6 (above). Interning left the core (M5). `limit` runs after decode; its bytes are paid for by the step-2 budget (§6.1). |
| B2 | State on a 20 Hz tick breaks "every event sees the state it refers to" | accepted | Reliable state (structure and reliable fields) every flush, never budget-deferred; `:newest()` rows and the scheduler on state ticks; the two-lane non-atomicity documented (§5.1, §3.5). |
| B3 | The column coder's prediction contradicts the notify model | changed | Resolved with R3 (above), decided from the measured table rather than by assumption. |
| M1 | Option-table definitions don't infer the way §3.1 and §3.5 claim | changed | `D & { from: ... }` adopted; the planner throws on unknown option keys with the path (§3.1). `timestamped` deleted rather than turned into a `t.subtick()` codec (R15). The request signature's spurious error is unproven and assigned to milestone 1 (§3.2). |
| M2 | `patch` typo claim is false on every path | accepted | §3.2 states exactly what is a compile error and what is a caller error. The overload set was not adopted: it changes nothing an author writes beyond a key check. |
| M3 | One word, several meanings | accepted | `limit` (inbound), `:maxHz` (outbound, in `interest`), `t.convert`, event `newest` deleted, `owner` only in `interest`, `priority` only on collections. |
| M4 | Every unreliable client event becomes a redundant, delayed input stream | accepted | "Unreliable" means only that (§5.2); input streams are the `inputs` extension with declared copies and jitter depth (§7.2). The `checks` roles drop the word `input` as a marker: unmarked fields are inputs, `:claim()` marks claims. |
| M5 | The intern table is a per-player memory sink and fills with junk | changed | Interning and templates moved out of the core into the `strings` extension: server-to-client only, per-audience tables, second sight, a byte cap (§4.5). |
| M6 | "Game code requires the shard" contradicts the build brief; stale fallback is a type lie | accepted | Shards are the API; a stale shard throws in Studio and fails `lync check` (§3.2). |
| M7 | Notify acks can't identify downstream frames | accepted | 12-bit downstream unreliable sequence as the ack target; demotion deleted; at most one reliable frame per player per flush (§4.1). Same fix as R1. |
| M8 | Verifiers in the shared schema, and codec methods multiply | changed | `:claim()` is a bare marker in `checks`, checked in `validate` (R8's one-hook rule) rather than a separate `:verify`. Codec methods are listed with their placement rule (§3.3). Integrity declarations live on the server view (§3.4, §6.2). |
| M9 | Principle 3 contradicted by §3.2 | accepted | Principle 3 restated; degradation made loud (§1, §3.2). |
| M10 | Principle 5 not met: names standing in for definitions | accepted | Each item is defined (budgets, hold cap, slots, tag lookahead, windows, groups, connections) or moved with its extension, which is specified to principle 5 before it is built (§7). Traps count, `EarlyReply` bound, `rejectClaims`/`inboundDelay` resolved per R14, §6.2.10 and the author's decision. |
| M11 | `rate` hurts honest players | changed | Declared `burst` with a stated default, client FIFO of `burst` messages, server slack `limitSlack`, network stalls listed as an honest cause (§3.4, §6.1). Rejected: counting by client send time; upstream frames carry no time and a client-stated time could not be trusted. |
| M12 | Over-engineering: cut milestones 1–5 to a library | changed | Accepted: Rust host to milestone 6, transformer and compiler plugins dropped, interning and `timestamped` out, accumulators to `interest`, `diff`/`replay` to milestone 6. Rejected: column coder stays in milestone 1 (author); tag, rekey, replay window, permutation and traps stay core (author); constraints moved to `checks` rather than cut. Rotation and seeds: deferred, author to decide. `watch` stays in milestone 3 (§8.3). |
| M13 | Milestones 1–2 can't be implemented: undefined wire and protocol | accepted | Frame layout, ids and widths, runs and counts, single-row encodings and rounding, tick headers, control messages and remotes, the hash, request slots and outcomes, inbound shape (§3.3, §4.1, §4.4, §4.6, §5.6). The permutation keeps id widths (§4.1). |
| m1 | "Non-canonical encodings refused" is undefined for the column coder | accepted | Canonical rules numbered; mode and k are free choices (§4.6). |
| m2 | `t.instance` drops the class type and nil policy | accepted | §3.3. |
| m3 | Codec constructor conventions disagree | changed | The f64 option table removed; `t.vector3f32` named; all `t.vector3` arguments required. Rejected: degrees for `t.angle` (every Luau and Roblox angle API takes radians), and error-in-unit for rotation and direction (no closed form; bits with a measured table). |
| m4 | Smaller surface inconsistencies | changed | Collections take no `from`; one `Target`; the two listening shapes explained (§3.5). Rejected: shards re-exporting `all`/`except`/`group`; one way to reach each name, on `Lync`. |
| m5 | Client reads allocate per change; `changed` fires twice | changed | Copy-on-write frozen records (measured: 7 ns `get`, 182 ns per change) instead of live records; the two-lane split documented; `:atomic()` rejected: a collection needing atomic changes declares no `:newest()` fields (§3.5). |
| m6 | Server Authority is absent | accepted | §5.2. |
| m7 | A record's owner is never declared | changed | Ownership and its boost move to `interest`, where they are declared (§7.2). |
| m8 | Research items dropped without a word | accepted | §12. |
| m9 | Hot-path bytes and CPU | accepted | Resolved with R5 (above); `FireAllClients` decided from targets; targets resolved once per flush (§3.5, §4.1). |
| m10 | `t.union` discriminant and a `kind` field | accepted | Declaration error (§3.3). |
| m11 | Open questions that are blocking proofs | accepted | Side-split error readability marked unproven with T6's evidence (§3.2). |
| T1 | `validate` uses `nil` for success | accepted | `true` accepts, `false` rejects. |
| T2 | One delivery option | changed | With event `newest` deleted, `lane` is the only delivery option. |
| T3 | Namespace naming | accepted | "Namespace" everywhere. |
| T4 | `key = t.int()` spends bits | accepted | Keys travel once; records go by slot and generation (§5.2). |

## Redundancy review (`v5-design-1-redundancy.md`)

| Id | Title | Outcome | Reason |
|---|---|---|---|
| R1 | Acks keyed by a tick several frames share | accepted | With M7. |
| R2 | The input stream has no downstream ack | changed | Input streams left the core; the `inputs` extension uses the upstream unreliable sequence as input index and carries its newest value downstream (§7.2). |
| R3 | `:newest()` both encoded once and predicted | changed | With B3. Per-viewer column FOR was measured and rejected: 7–31% fewer bytes for per-viewer encoding (§5.3). |
| R4 | Per-connection intern ids defeat encode-once | changed | With M5: per-audience tables and second sight, in the `strings` extension. |
| R5 | The header repeats the tick and the ack | accepted | With m9; the idle heartbeat is an ack-only frame sent only when an ack is owed. |
| R6 | Section `kind` + `length` can't do what it is there for | changed | With B1, using counts per list rather than a presence bitmask (1 bit per empty list). Rejected: checking `limit` before decoding the body; without lengths the body must be read to reach the next message, and the budget already paid for it. |
| R7 | Per-build field rotation is subsumed and drags in seven surfaces | **deferred, author to decide** | Kept as in draft 1, by the author's decision: `[build] seed`, `[rotate] fields`, `seed = "release"`, "Prepare release", the seed in `HELLO` (§6.2.4, §8). Checked per the author's rule: the tag does not defend the same thing, since an extractor holding the key with a static encoder passes the tag and is stopped only by the new build's field order. The contradiction with "same wire" is resolved by stating the wire facts both paths share (§3.2). The two ways to disable it (`seed = 0`, `rotate.fields = false`) remain for the author. |
| R8 | Four rejection hooks and two rate limiters | changed | Middleware deleted entirely rather than restricted; `validate` is the one function hook; `:claim()` is a bare marker; `cooldown` folded into `limit` (§6.1, §7.1, §7.2). |
| R9 | Event `newest` is the worst-ranked scheme | accepted | Deleted; singleton collections (§3.4). |
| R10 | Per-tick accumulation serves only the extension | accepted | Per-collection FIFOs merged by `priority` × age (§5.4). |
| R11 | Priority and rate set twice; `:owner()` means three things | accepted | §3.4, §7.2. |
| R12 | Oversized unreliable items handled three ways | accepted | Planner refusal only (§3.4, §12). |
| R13 | Four artefacts where two suffice; two generators | accepted | `manifest.json` and `report.md`; the plugin regenerates only with `StringValue` configuration. The debug map's job (decoding rotated captures) is done by the planner given the build seed, which the shard, manifest and `HELLO` carry (§8.1); rotation itself is unaffected. |
| R14 | Traps declared two ways | accepted | Only `:trap()` on the server view. Checked per the author's rule: generated hidden ids arrive as unknown ids, which are already refused as `malformed` with an exact trigger, so the measure relied on defends the same thing. |
| R15 | `timestamped` costs 8 bits per event | changed | Deleted with no header index: the frame tick dates downstream messages and the newest ack upstream ones (§12). |
| R16 | Request ids explicit on a counting lane | changed | 4-bit slots, but explicit on the ask: the two ends free a slot at different times, so implicit numbering could disagree (§5.6). |
| R17 | The handshake sends per-definition hashes and a seed | changed | `HELLO` is version, seed and schema hash; per-definition hashes dropped (diagnosed offline). The seed stays because rotation does: deferred with R7, author to decide. Unsolicited `WELCOME` pending a Studio check (§4.4, §11). |
| R18 | `get` clones on every call | accepted | Copy-on-write (§3.5). |
| R19 | The notify ring is twice the ack window | accepted | 17 entries in a buffer (§5.3). |
| R20 | Codec overlaps | accepted | `t.vector3f32`, `t.convert`, `t.number(…, 1)` with integer `min` is a declaration error, `t.int()` documented, `t.cframe` builds once (§3.3). |

## Client-side refusals re-evaluated

The rule: judge each measure by the cost it imposes on tampering against its runtime, wire, size and developer
cost. "A determined attacker can defeat it" is not a reason by itself, and neither is "a universal counter
exists": where build-time, per-server or per-session generation can make the counter specific, the measure is
judged by that recurring cost. Platform limits, Creator Store rules, Luau performance and facts-not-verdicts still
apply.

| Measure | Earlier reason | New verdict | Reason |
|---|---|---|---|
| Keyed tag, rekey, replay window | M12: extension-grade, since `require(Net)` bypasses them | kept, core (§6.2.1, §6.2.2) | Author decision. They price raw senders, replayers, injectors and blocked calls; the API route is priced by other measures. On the generated path the tag function, key and counter live in the shard with per-build constants, so locators and reimplementations are per-release work. |
| Per-server id permutation | Draft 2: the tag rejects every frame not built by Lync's encoder; falls to "one shared memory scan" | kept (§6.2.3) | The tag does not defend the same thing: an extractor holding the key with a static encoder passes it. The "one shared scan" limit is not universal: the table is read per server in every session, and on the generated path it lives in the shard, so locating it is per-build work. Zero bytes per frame. |
| Per-build field-order rotation | R7, draft 2: subsumed by the tag; "any use of Lync's encoder" | kept as in draft 1; R7 deferred, author to decide (§6.2.4) | Not subsumed (see R7). Zero run-time cost measured; static tooling is rebuilt per release. |
| Tag constant rotation | Not adopted in draft 1 or 2 | adopted, `rotate.tag` (§6.2.4) | Same opcodes, zero cost `[client-security-build §2.3]`; makes tag reimplementations and constant-based locators per-release work. |
| Caller identity probe | Defeated by `setthreadidentity`; Studio command bar false positive | adopted, sampled (§6.2.7) | Executor threads run at identity 8 by default, so naive API drivers report themselves. The counter is one call and generation cannot vary it, but the measure is judged on cost: one failing `pcall` per sampled call, at most 34 µs/s, no bytes, false positives only in Studio. Member choice and logging behaviour unverified, checked in milestone 5. |
| Caller source check | `loadstring` names chunks anything; modules called from many places | adopted with the build's per-definition script lists (§6.2.7) | Honest client code has no `loadstring`, so its sources are game scripts. Checking against the scripts the build found referencing each definition makes the counter specific: the attacker must read, per build and per definition, which chunk name to use. 57–72 ns per probe. The clone mapping is unverified; if Studio shows honest sources don't follow it, the source check is removed. |
| Client decode failures reported to the server | Reported by the attacker's own client: suppressible and forgeable | adopted (§6.2.8) | Zero cost; suppression needs a patched Lync; a client's report can only incriminate itself. |
| Clock-rate beacon | Draft 2: narrow coverage | adopted, opt-in (§6.2.9) | Narrow coverage is not a reason. About 4 B per beacon. Default off until mobile jitter is measured (§11), because its noise estimate is unmeasured on Roblox. |
| Early-reply check | Draft 2: forging a reply is pointless when the attacker can answer through Lync | adopted as `earlyAnswer` (§6.2.10) | Pre-answering a predictable timed prompt gains up to one round trip, so it is not pointless. One clock and ping read per server ask, no bytes. `unknownReply` covers only answers sent before the ask was. |
| Reachability (automatic traps) | Draft 2 dropped it without a reason | adopted (§6.2.6) | Every unreferenced client-sent definition becomes a trap, per game, at one table index per message. |
| Decoys | Draft 2: milestone 7 extension | core measure, milestone 5 (§6.2.11) | Author decision. Specified with `refers`, per-viewer sections and `maxPerViewer`. |
| Canaries | Anticheat brief: `:canary()` in the shared schema | adopted on the server view (§6.2.12) | A marker in the shared schema would tell the client which field is the canary. Values are per record per server, not per viewer: the echo's sender is already known, and encode-once holds. |
| Hook and environment checks | Defeated by documented executor APIs; false positives; universal bypass | still refused (§6.2.13) | Not because a counter exists: the standard tools already pass them without extra work (spies wrap hooks in `newcclosure` by default and hook in place), so they price nothing, and no generation changes the engine functions they inspect. Adonis ships its equivalent off for false positives; `getfenv` forms deoptimise every script and are barred from the Creator Store. |
| Downstream tags and a client replay window | They protect only the attacker's own view; a PRF per recipient | still refused | The view they protect is the tampering client's own. Cost: a PRF per recipient per frame (0.48–5.5 µs native each), which at 100 players × 60 Hz is up to about 3% of a core, and the end of `FireAllClients`. The refused-frame report covers non-canonical injection at no cost. |
| Masking or whitening frames | +62% to +272% bytes after zstd; stops nothing above the wire | still refused | Re-judged with generation: masking only the incompressible bit section would cost about 0 bytes, and a per-session key would make passive spy reading per-session work. But everything it hides is readable through the typed API, whose names game code fixes, so no generation can make that counter specific; every forge it blocks the tag blocks; CPU per byte at the tag's rate on both ends; per-connection keys end `FireAllClients`; masking the tail costs +62–272%. |
| Per-session upstream id shuffle | Marginal over the tag and server shuffle | still out | It is per-session already; the read it forces is the same memory read the per-session tag key forces, in the same pass, so it adds no recurring work. Costs a decode table per player (about 20,000 slots for 200 definitions × 100 players). |
| Runtime field shuffling | Generated straight-line code can't follow it | still out | It would turn generated codecs into the table-driven path, 2–3x slower per record write (measured, build brief §2.3); rotation gives per-build variation at zero cost. |
| Codecs scattered into game scripts (build brief §3.2) | 5.0x bytecode, noisy diffs, the central queue is found by `getgc` | still refused, reason changed | Re-judged: with per-build shapes the central queue would need per-build discovery, and removing the shard module would make the `require(Net)` route per-build work, a real recurring cost. Refused because it rewrites the developer's own scripts on every build (merge conflicts, `UpdateSourceAsync` races with open scripts), costs 5.0x encoder bytecode, and removes the typed shard API, which the author made the primary source of types. Its zero-cost parts are adopted: per-build tag constants and the permutation table in the shard. |
| Per-player shard variants from a pool (build brief §3.3) | Join-time dependency and per-player instances for what session shuffle gives | still refused, reason changed | Re-judged: per-player variation would make byte tools per-player, but the counter a variant needs (read this variant's constants from the loaded shard) is exactly what a rotation-aware tool already does, so it adds no recurring work beyond rotation. Costs: `PlayerGui` arrives after spawn, a `ResetOnSpawn = false` container, client start waiting on the clone, one replicated instance per player. |
| Per-client or per-server generated code | Clients have no compiler; server `loadstring` can't reach clients as code | still refused | Platform: `LoadStringEnabled` is server-only and `NotScriptable`. |
| Obfuscation, VMs, `getfenv`/`setfenv`, `loadstring` in runtime, shards or plugin | Creator Store; fast calls | still refused | Creator Store rules and the deoptimisation are unchanged. |
| darklua renaming | Not seedable; local names are not shipped | still refused | It changes nothing in shipped bytecode, so it prices nothing. |
| Manifest self-attestation of client scripts | `Source` is `PluginOrOpenCloud` | still refused | Platform. |
| Build-time id rotation | Subsumed by the per-server shuffle | still refused | The per-server permutation varies ids per server, more often than per build. |
| Generated hidden trap ids (`traps = N`) | R14: two ways to declare traps | still out | They arrive as unknown ids, already `malformed` with an exact trigger; reachability is the automatic trap that reaches API drivers. |
| Per-viewer slot permutation (decoy companion, watermark) | Anticheat brief: required for decoys | refused | Keys travel in adds, so comparing key sets finds what slot permutation hides; it costs per-viewer slot encoding. |
| Low-order watermarks in quantized values | Weak; visible jitter | still refused | Visible jitter for the honest player, and rounding removes it. |
| Quiet mitigation (`rejectClaims`, `noLookAhead`, `inboundDelay`) | Draft 1: a hook the game calls | deleted | Author decision: no automatic or library-applied consequence; the game builds it on the observer. |
| Client-side decoy filtering | Any flag in memory is a filter for the cheat | still refused | Unchanged. |
| Client-chosen rewind timestamps | Backtrack advantage | still refused | Unchanged; `rewind` uses the perceived tick from the newest ack. |
| Calls per second above any plausible frame rate | Information-only signal | covered | The inbound frame budget reports the same fact as `overBudget` with an exact trigger. |

## Decisions made in this revision

1. **One factual observer event, `anomaly`,** with lowercase reasons like every other API literal; draft 1's
   `Drop` and `Suspicion` merged. `Malformed` and `OutOfBounds` merged into `malformed` with the numbered §4.6
   rule as evidence. Renamed to say what happened: `HandshakeAbuse` → `repeatedHello` (evidence `hashChanged`),
   `Replay` → `duplicate` and `staleSeq` (every occurrence, so `replayNoise` is gone), `RateExceeded` →
   `overLimit`, budget drops → `overBudget`. Added `impossibleAck` (the free ack consistency check draft 2 had lost
   from its text). Evidence is numbers only; `lane` is 0 or 1.
2. **Delivery limits** keep draft 1's window and caps; occurrences past a cap go into one per-player `suppressed`
   event with per-reason counts, exempt from the caps.
3. **Actions per fact:** frames or messages that break the protocol are dropped; `unreachable`, `earlyAnswer`,
   `decoyReferenced` and `canaryEchoed` are delivered and reported, since dropping them would be a judgement.
4. **`:newest()` rows keep no prediction** in the core, from the measured table (§5.3).
5. **Record fields ordered by name** at seed 0, since the planner can't see source order
   (`probes/design-2/field_order.out`); rotation permutes that order.
6. **Wire facts both paths share** stated exactly; the schema hash is computed at seed 0 and the seed travels
   separately in `HELLO` (§3.2, §4.4).
7. **Permutation** by Fisher–Yates over xorshift32, seeded per server and per namespace, 4 B in `WELCOME`
   (§6.2.3).
8. **Control messages** tabulated, with `REPORT` (client-reported counts) and `BEACON` added; 7 of 8 types used.
9. **Caller probe defaults:** share 0.05, at most 10 per second.
10. **Catch-up adds carry the partition baseline** and precede the partition's update section, so shared updates
    apply correctly to a new viewer (§5.2).
11. **Ack-only frame** when an ack is owed and nothing else is sent (§4.1).
12. **`t.optional` allowed in arrays and maps;** the instance array is bounded by the byte budget, and an
    unreferenced entry is `malformed` (§3.3, §4.6).
13. **Integrity declarations on the server view** (`trap`, `refers`, `decoys`, `canary`), never in the shared
    schema.
14. **Milestone 5 carries every client-side measure,** including decoys and canaries moved from milestone 7, and
    is proven by an adversarial client in the simulated world (§9, §10).
15. **Principle 1 reworded** so client measures are first-class without weakening server authority.
16. **`clockBeacon` defaults off** until mobile jitter is measured.

## Deferred, and where it went

- Interning and templates: `strings` extension (§7.2).
- Constraints and claim fields: `checks` extension, with `drop` or `clamp` and every failure reported.
- Ownership, distance and first-send boosts, per-field rate caps: `interest` extension.
- Prediction of `:newest()` rows: `acked` extension.
- Input streams and jitter buffers: `inputs` extension.
- The Rust/mlua CLI host, `lync diff`, `lync replay`: milestone 6.
- Roblox-only measurements (compression context, `PostSimulation` send timing, loss, jitter and RTO, duplication,
  caller-probe behaviour): §11, pending, not blocking.
- Typing proofs (`Lync.request` signature, side-split errors): milestone 1.
- Rotation and seed (R7, the rotation parts of M12 and R17): kept as in draft 1, deferred to the author.

---

# Draft 2 to draft 3

2026-10-15. Applies `.data/docs/reviews/v5-design-2.md` (review-2: B, M, m, T ids) and
`.data/docs/reviews/v5-design-2-redundancy.md` (redundancy-2: S1–S15), and adopts
`.data/docs/research/diagnostics.md` (cited `[diagnostics §n]`). Section numbers refer to draft 3: `v5.md` and its
new companions `v5-collections.md`, `v5-integrity.md`, `v5-tooling.md`, `v5-extensions.md`.

**Count:** 43 findings. Accepted 29, changed 14, rejected 0. Some changed findings had parts rejected (M11, M12,
S7, S13); each row says which.

**Length.** The core went from 1316 to about 880 lines while gaining the full milestone 1 and 2 wire. Moved out:
collections (milestone 4), client-side integrity rationale and measures (milestone 5), tools (milestones 3 and 6),
extensions (milestone 7). Removed as duplicates of this log: draft 2's §6.2.13 refused list, §12 dropped list, and
history citations in the body.

## Overlaps resolved once

| Overlap | Findings | Resolution |
|---|---|---|
| Encode-once against per-player headers and fields | B3, S3 (and M4's decoy part) | Chunks are the unit of sharing and start byte-aligned downstream; instance indices are chunk-local; the tail layout of a shared chunk is defined; the downstream unreliable seq is server-wide, so unreliable frames can be broadcast; a shared reliable frame uses `'11' u16` when its recipients' last ticks differ (`v5.md` §4.1, §4.2, §4.4). Decoys cost their viewers per-viewer chunk copies, stated in `v5-integrity.md` §8. |
| Hot-path raise cost against strict decode | diagnostics §9, with review-1 B1 and redundancy R6 | The decoder returns a rule number and refuses the frame whole; nothing raises on the refusal path; one `pcall` per frame catches unexpected raises as `decoderRaised` (`v5.md` §4.8). |
| Stored 12-bit sequences aging | M2, S1 | Every stored sequence is extended to a full counter against the newest seq received (S1's fix rather than ordering by tick: it has no horizon at all) (`v5.md` §4.4). |
| Trap and reachability | S5, S6, diagnostics §4.2 | One fact, `unreachable`, evidence `declared` (`v5-integrity.md` §3). |
| Fact shape and event stream | T1, M8.7, M8.8, M9, S6, S13, diagnostics §5 | One frozen `Fact` discriminated on `reason`, no `kind`; per-frame `frame` events replaced by `Lync.counters()`; coalesced facts carry the last occurrence's evidence; validator outcomes leave the fact stream; 31 reasons become 17 core plus 6 of milestone 5 (`v5.md` §7.3, §7.4). |
| Clock-beacon knobs | M7, S7 | Window, fit and threshold become constants (5 s, 12 windows, 0.006); the beacon range is 0.5–1.5 s and the restart gap 3 × beacon (`v5-integrity.md` §6). |
| Configuration naming and knobs | m6, S7, M6 | Grouped tables per measure; transport tuning moved to protocol constants (`v5.md` §4.9); `configure` never throws for being late (`v5.md` §7.5). |
| Runtime-path typing degradation | M11, diagnostics §6.3 | `solverOff` from `lync check` unless `[types] solver = "new"` (`v5.md` §3.2). |

## Review-2 (`v5-design-2.md`)

| Id | Title | Outcome | Reason |
|---|---|---|---|
| B1 | Dropped asks leak request slots forever | accepted | Every ask read is answered (`rejected` for traps, `unresolved`, `limit`, `validate`); a 1-bit slot epoch lets the asker reclaim a slot on timeout after frame-level drops; conflicts are the fact `slotConflict` (`v5.md` §5.2). |
| B2 | Milestone 1 still can't be built from the text | changed | All items closed: bit order (`buffer.writebits` order, checked: `probes/design-3/bitorder.out`), EG-k bit layout, padding points (`align` before downstream chunks), flattening of nested types to columns, rule 2 off-by-one, `t.int()` capped at \|v\| ≤ 2^52 (zigzag checked exact), codec details, the hash input byte layout. Changed for `t.number`: a non-integer step count is a declaration error (`numberStep`) rather than a floor fallback, so the maximum error stays step/2 (`probes/design-3/number_steps.out`). |
| B3 | Encode-once chunks conflict with fields that differ per frame | accepted | See overlaps. |
| M1 | High-frame-rate clients trip the budget; per-namespace remotes multiply calls | accepted | The client auto-flushes at most every 1/60 s; one remote pair per connection carries every namespace through namespace segments in the toc (`v5.md` §4.1, §5.1). |
| M2 | Newest-wins on a 12-bit sequence freezes idle records | changed | See overlaps: extension, not tick ordering. |
| M3 | Any schema typo segfaults the analyzer on the runtime path | accepted | Rule: type functions never call `error()` on user-derived input; a typo schema is a milestone 1 typing proof (`v5.md` §3.2, §10). |
| M4 | Decoys are visible on the wire and draw on shared slots | changed | Decoy updates ride in a per-viewer copy of the partition chunk; decoy slots come from a pool of `maxPerViewer` slots shared by all viewers, counted in `maxRecords`; key collisions throw `decoyKeyLive`. Not adopted: per-viewer slots outside the shared range, since a separate range would itself mark decoys (`v5-integrity.md` §8). |
| M5 | Reliable fields replicate every flush with no budget or rate knob | changed | Documented, and a collection option `reliableRate` (Hz, 1–60, on the state clock), named like `state.rate` rather than `reliableHz` and not limited to divisors of 60 (`v5-collections.md` §1). |
| M6 | `Lync.configure` brings back start-order rules | changed | `configure` never throws for being late: options in `WELCOME` apply to later connections, server-only ones from the next flush, and `state.rate` at the next state tick through a new control message `RATE`. Neither proposed fix (fixing server-wide options at first use, or delaying `WELCOME`) removes the race, since Script start order is undefined (`v5.md` §7.5). |
| M7 | The clock beacon's parameters exclude each other | changed | See overlaps. |
| M8 | Milestone 2 gaps | accepted | Joiners: the server holds sends for un-welcomed players, so broadcasts reach them late, and `FireAllClients` covers welcomed players only (§5.3). `MISMATCH`: server drops its sends and reports `schemaMismatch`; control misuse and data before `WELCOME` are malformed rule 7. Untagged `HELLO`s: defined rule (§4.5). Tag: ships in milestone 2 with the frame format. Request edge cases: `slotConflict` cases and holds. Frame size: rule 8. Observer scope: §7.3 lists every milestone 2 reason. Coalescing: per key, last evidence. |
| M9 | Wording that still judges | accepted | "Reports what it observes"; the confidence quotation removed; evidence `identitySucceeded`, `sourceUnlisted`; one action word, "dropped"; "beyond `REKEY` and request outcomes". The word "anomaly" also went (diagnostics §11): the event is a fact. |
| M10 | Leanness | accepted | See "Length" above. |
| M11 | "Degradation is loud" can't be built | changed | `lync check` part adopted (overlaps); the selene claim removed. Rejected: a Studio line on every runtime-path start. Lync can't tell which solver is on, so it would print for every runtime-path user in every session, new solver included, and train people to ignore Lync's output. |
| M12 | The client's `limit` FIFO reorders messages | changed | Documented: under `limit` delivery order holds per definition only, and a held `invoke`'s timeout runs. Rejected: holding every later message behind a held one, which would stall all of a client's traffic for up to a second whenever game code exceeds one definition's limit (`v5.md` §5.4). |
| m1 | "The build seed changes exactly two things" contradicts §3.1 | accepted | Only record fields rotate; variant order doesn't. |
| m2 | `t.enum(Enum.Material)` is `Codec<unknown>` on the runtime path | accepted | Listed with list enums (§3.2). |
| m3 | Canary matching and collisions | accepted | Exact match; canary fields need `maxBytes` ≥ 12 and canaries are always 12 characters. |
| m4 | `maxRecords` against the slot reuse delay | accepted | `maxRecords` counts slots; no free slot is `recordLimit` at the caller. |
| m5 | The permutation's "per-build work" is unsupported | accepted | Restated as per session: read the seed or table. |
| m6 | Two naming conventions in `Lync.configure` | accepted | See overlaps. |
| m7 | Reachability's notion of "escape" | changed | Rather than tighten escape analysis, the rule over-approximates: a definition is reachable if its name appears as a field access or string literal anywhere in client code; only a non-literal index of the shard value makes a namespace incomplete. Sound against honest code, and structured games keep coverage (`v5-integrity.md` §3). |
| m8 | Downstream reliable frames have no size cap | changed | Reliable frames split at 16,384 B both ways and every message must fit it, pending the engine's limit (§10). |
| m9 | The tag specification is incomplete | accepted | PRF input layout, output bits, cover from byte 0, old key until `REKEY-ACK` (§4.5). |
| m10 | Integrity declarations take unchecked strings | accepted | `unknownField` at the caller; the generated path types them as literal unions. |
| m11 | Unreliable `limit` and pre-`WELCOME` semantics | accepted | Both drop and report `sendDropped`. |
| T1 | Two meanings of `kind` | accepted | The fact type has no `kind`. |
| T2 | `callerProbe.share` | changed | `callerProbe.oneIn`, an integer that travels exactly in a u8, rather than a fraction rounded to 1/255. |

## Redundancy-2 (`v5-design-2-redundancy.md`)

| Id | Title | Outcome | Reason |
|---|---|---|---|
| S1 | Rows ordered by a stored per-record 12-bit sequence | accepted | See overlaps. |
| S2 | The join hold equals the inbound burst | changed | Hold cap a protocol constant of 32,768 B and the byte burst's minimum 49,152 B, a margin of one full frame, rather than an overhead formula (`v5.md` §5.3, §7.5). |
| S3 | Per-player sequences and tick deltas defeat broadcast | accepted | See overlaps. |
| S4 | An ack-only frame for every owed ack | accepted | Owed after 2 frames or 100 ms. |
| S5 | `trap` and `unreachable` report the same fact | accepted | See overlaps; the source probe skips definitions with no listed scripts. |
| S6 | 31 reasons where 21 keep every fact | accepted | All merges adopted; with per-direction id spaces, wrong direction and lane are no longer expressible apart from an unknown id. |
| S7 | Knobs that should be constants; settings reachable two ways | changed | Adopted: the constants table (`v5.md` §4.9), `permuteIds` deleted, one off-switch for the probe, `tag.cover` range 0–16,384, the reachability note. Rejected: making `inbound.*.frames` constants, since `Lync.flush()` makes a client's frame rate the game's choice. Rotation's knobs stay with the author. |
| S8 | `REPORT` sent for probe counts alone | accepted | Only with a non-zero fact count, never forcing a frame. |
| S9 | Canary state per player; buffer lookups allocate | accepted | Server-wide map, per-viewer bitset, length test first. |
| S10 | One id space for both directions and request roles | accepted | Three spaces per namespace (§4.6). |
| S11 | Generation bits on the ordered lane | accepted | Generations are counted on both ends; only unreliable rows carry them. |
| S12 | Unspecified framing and ordering details | accepted | Rows chunks have a collection index and count; a re-pended record is appended with its age restarting. |
| S13 | Two channels for local game-code mistakes | changed | `validatorError` and validator outcomes left the fact stream (native report and counters). Rejected for `sendDropped`, `missedFlush` and `remotesMissing`: the call was valid when made and the condition is transient (a join stall), so throwing would kill game loops for no mistake of theirs `[diagnostics §4.2]`. |
| S14 | The downstream unreliable tick could be 8 bits | accepted | `tick:u8`, extended against the client's own estimate. |
| S15 | `WELCOME` repeats connection-global fields | accepted | Epoch and rate only in the first `WELCOME`, and in `RATE`. |

## Diagnostics research: adopted, and where draft 3 departs

Adopted, in `v5.md` §7 unless noted: one lowerCamelCase code per fact or error with a registry page each, families
fixing channels, `lync explain` and docs links; the message grammar, `show()` and the banned words; string-only
throws; positions from the `debug.info` walk and recorded constructor lines; the channel table; the fact shape and
per-observer pooled threads; coalescing with last evidence and caps counted per player and reason; counters in
place of per-frame events; console rules (constant text, `LogService:Warn` templates, at most 2 lines per code per
window, clients print only local facts, one `console` switch, no verbosity levels); `profile`; validators under
`xpcall`, `validatorYielded`, thread-status detection of throwing `handle`s, `decoderRaised`, `remotesMissing`;
the type-function marker rule; build diagnostics as LSP Diagnostics in `human`, `json` and `github` formats with
exit codes 0–3 and plugin callbacks (`v5-tooling.md` §3); testing by code, position and evidence with a
self-linting registry (`v5.md` §9).

Departures:
- **No `configureLocked`.** `configure` never locks (M6), so the code has nothing to report.
- **No direction and lane rules.** The research kept them as malformed rules 10 and 11; per-direction id spaces
  (S10) make them unknown ids under rule 7.
- **`LogService:Warn` with a `warn` fallback.** Its grouping by template in the Error Report is unverified, so
  until milestone 2's Studio check the same constant text goes through `warn`, which keeps the one-row property.
- **`player` on server-local facts** is the player concerned (a held send, a missed flush) rather than nil, so a
  held send to one player can be attributed.

## Client-side measures re-judged in draft 3

The rule of the draft-2 section stands. Changes since: `permuteIds` removed (one off-switch would remain only for
tests, which the seam covers; the measure costs nothing at run time); the tag, replay window and permutation moved
to milestone 2, since they are part of the frame format; decoys gained a per-viewer chunk copy to remove the
placement tell (M4); the per-viewer slot range was refused for the reason under M4.

## Decisions made in draft 3

1. **One remote pair per connection**; namespaces numbered server-wide by first use and carried as segments in a
   table of contents; `HELLO`s answered in arrival order; a `HELLO` for a namespace not yet loaded waits 10 s.
2. **Chunks** as the unit of sharing; downstream chunks byte-aligned, upstream packed; run, state, remove and rows
   chunk headers; runs in call order across namespaces.
3. **LSB-first bits** (the order of `buffer.writebits`), the EG-k bit layout, fields over 32 bits split low first.
4. **Column flattening** for every codec, residuals modulo the code count (which keeps `t.int()` exact), raw columns
   for floats and custom codecs, single-row request runs.
5. **Codec edges:** `t.int()` to 2^52; integer step counts for `t.number`; `t.direction` normalises; `t.rotation`
   refuses a position; the smallest-three sign and tie rules; the axis-aligned form as an encoder rule.
6. **Tag layout** and the untagged-`HELLO` rule; tag, replay window and permutation in milestone 2; permutation by
   Fisher–Yates over xorshift32 per id space.
7. **Holds on both sides** for un-welcomed players, 32,768 B each.
8. **Slot epochs**, `slotConflict`, and late answers as a counter.
9. **`RATE`**, the eighth control type.
10. **Fact set:** 17 reasons in milestone 2, 6 in milestone 5, `constraint` in `checks`.
11. **Decoy pool slots** shared by all viewers.
12. **16,384 B** per message and per reliable frame, both directions, until the engine's limit is measured.
13. **`[types] solver`** in `lync.toml`.

## Dropped (draft 2's §12, kept here)

Event `newest`; `timestamped`; runtime demotion of oversized unreliable items; `report.json` and `debugmap.json`;
the roblox-ts transformer; compiler plugins and `rans`; suspicion weights, scores and `Lync.suspicion`;
quiet-mitigation hooks; the unreliable-event deadline; `:initial()`; an audience-by-field shortcut. Reasons are in
the draft-1-to-2 tables above.

---

# Draft 3 to 3.1

2026-10-15. Applies `.data/docs/reviews/v5-design-3.md` (review-3: M, m ids), a builder-readiness review. New
probes: `probes/design-3/golden.luau` (the golden set) and a re-run `number_steps.luau`.

**Count:** 12 findings. Accepted 9, changed 3, rejected 0.

**Author decision recorded:** per-build rotation is kept (client hardening at zero run-time cost). The draft-1-to-2
outcome "deferred, author to decide" for R7, M12's and R17's rotation parts, and draft 3's "deferred to the author"
notes are closed: rotation is part of the design (`v5.md` §4.5, `v5-integrity.md` §2).

| Id | Title | Outcome | Reason |
|---|---|---|---|
| M1 | A server-wide unreliable `seq` breaks the ack window and extension | changed | Neither proposed fix: two downstream unreliable frame kinds instead. Event frames (`'0' tick:u8`) carry runs only and no seq, so they stay identical for every recipient and broadcast (B3, S3); state frames (`'1' seq:u12 tick:u8`) carry rows only, with a per-player seq, so the ack window and extension cover consecutive frames and notify works. Unreliable events need no seq because they are never resent. Cost: one more call and a 9-bit header on a state tick when a player gets both rows and events (`v5.md` §4.4). |
| M2 | The control chunk format is undefined | accepted | `control chunk := type:u3 count−1:EG0 rows`; protocol version 1; tail order by the general rule (`v5.md` §4.1, §4.6). |
| M3 | A welcome and the held sends it releases arrive in an order rule 7 refuses | accepted | Released holds follow the `WELCOME`'s control chunk; control messages take effect as decoded, for the rest of the frame; rule 7 judges a namespace "when it is decoded" (§4.6, §4.8, §5.3). |
| M4 | Wrong-lane messages are no longer detected | accepted | Rule 7 covers a message on a lane its definition doesn't use, both ways, plus control chunks and rows in the wrong frame kind. |
| M5 | Integer codes at 2^53 | changed | EG-k redefined as EG-0 of ⌊u/2^k⌋ then the k low bits, which is the standard equivalent and exact for every code up to 2^53 − 1; `t.int()` is −2^52 … 2^52 − 1 and `t.int(min, max)` within it; column codes defined per codec on an interval of n ≤ 2^53, residuals wrapped into [−⌊n/2⌋, ⌈n/2⌉ − 1] (bools fall out as XOR). The review's "zigzag the plain difference" was not used: for negative differences near 2^53 it isn't exact (§3.3, §4.1, §4.3; G9 in `golden.out`). |
| M6 | Milestone 1 byte-level choices left open | accepted | Presence 1 = present; zero-row columns write nothing; bools are 2-code columns; the reference encoder's tie rule; instances once per chunk in first-reference order (rule 9); axis-aligned rotations in lexicographic matrix order; the quaternion branch rule and component order; color and direction decodes; every numeric hash parameter a `num`; collections' `from` and lane; enums up to 65,535 items. |
| M7 | Milestone 2 behaviour left open | accepted | Untagged `HELLO` frames don't advance the count (G4 at count 0); a first reliable frame uses `'11'`; `received` bit i is seq − 1 − i; every seq and epoch starts at 0; reliable frame first in a flush, ack in the first frame; buckets start full and refill continuously. The `REKEY` switch point is also defined (§4.5). |
| m1 | A late answer after a reclaim matches two rules | accepted | Epoch first, then the `slotConflict` cases, now numbered (§5.2, §7.3). |
| m2 | Splitting shared runs across 16,384 B frames | changed | Chunks are capped at 16,256 B (960 B unreliable) and messages at 16,000 B (960 B), so every chunk fits an empty frame; the review's 16,000 B figure became the message cap, with the chunk cap set from the frame overhead (§4.1, §4.9). |
| m3 | A cited probe disagrees with its rule | accepted | `number_steps` re-run under the stated rule: `t.number(0, 1, 0.3)` is `numberStep`. |
| m4 | "Namespace hash" and "schema hash" | accepted | "Schema hash" throughout. |
| m5 | `t.angle` steps rely on ⌈⌉ | accepted | n uses `t.number`'s 1e-9 tolerance, then ⌈⌉ (`number_steps.out`). |

**Golden frames.** The review's proposed set is adopted as `v5.md` §4.10, corrected and completed under 3.1's rules:
G2–G6 are byte-identical to the review's build; G4 is the count-0 frame (M7.1); G5 uses `received` bit i = seq − 1 − i
(M7.3); G6 writes `max` as a `num` (M6.9); G7 (`HELLO`), G8 (a column block, with the reference encoder's mode
choices) and G9 (the `t.int()` extremes) are new.

**Decisions made in 3.1.**
1. Two downstream unreliable frame kinds (M1).
2. The `REKEY` switch: the client tags with the new key from count 0; the server tries the new key while a `REKEY`
   is pending, and the first match must carry `REKEY-ACK`.
3. `[rotate]` removed from `lync.toml`: with rotation kept, the build seed is its one switch, which closes the knob
   overlap redundancy-2 S7 had left to the author.
4. Chunk and message caps as protocol constants (16,256 / 16,000 B reliable, 960 B unreliable).

---

# Draft 3.1 to 3.2

2026-10-15. Folds in what the milestone 1 build found: the builders' rulings recorded in `m1-plan.md` §6, the
`columnMinRows` benchmark, and four open questions. New builder work and milestone 2 interfaces are in
`m1-plan.md` §6.1–§6.2.

**Count:** 18 items. Accepted 15, changed 3, rejected 0.

**`columnMinRows` benchmark** (unit C, `bench/rows.luau` (planned; built as `test/codec/min_rows.luau`, commit `f1fbfd7`)): bits of n single rows against one column block, summed
over `strike`, `announce`, `fighters` and a `{ t.int(0, 100) }` record, 200 draws.

| n | constant | ±1 noise | Gaussian σ = 50 | 10% sparse |
|---|---|---|---|---|
| 1 | 174.7/295.1 | 174.8/295.7 | 174.6/280.2 | 174.5/294.3 |
| 2 | 348.3/351.0 | 349.1/407.7 | 349.9/425.5 | 348.9/356.9 |
| 3 | 523.1/352.9 | 523.6/467.4 | 523.7/535.5 | 523.7/382.2 |
| 4 | 697.9/353.3 | 698.1/517.9 | 698.2/642.8 | 697.9/403.2 |

| # | Item | Outcome | Reason |
|---|---|---|---|
| 1 | `columnMinRows` | accepted | 3: the smallest n where the block is no larger in 3 of 4 patterns (`v5.md` §4.9, §4.10). |
| 2 | Serialization: defaulted options present with resolved values | accepted | One byte sequence per schema whether a default is written out or not (`v5.md` §4.7). |
| 3 | Serialization: options a kind doesn't take are absent | accepted | As 2. |
| 4 | Serialization: a union variant is a full codec (type 23) | accepted | The record serializer is reused as is. |
| 5 | `hasInstances` covers `data` or `reply` | accepted | One flag per definition; an ask run of a definition whose only instances are in `reply` pays one EG-0 bit (`v5.md` §4.1). |
| 6 | `t.vector3f32` in a column block: three raw columns | accepted | Consistent with `t.f32` (`v5.md` §4.3). |
| 7 | `notADefinition` | accepted | One fact, one code (`v5.md` §3.4). |
| 8 | `duplicateName` for a repeated enum item | accepted | |
| 9 | `nameLength` (namespace 1–64 B, others 1–65,535 B) | accepted | |
| 10 | `mapKey` for a wrong collection key | accepted | Same constraint as a map key. |
| 11 | `newestWidth`'s codec list | accepted | Listed exactly in `v5.md` §3.3. |
| 12 | Worst-case sizes bound column blocks too | accepted | `v5.md` §3.4. |
| 13 | `t.rotation` is not idempotent | changed | Neither (a) nor (b): canonical means idempotent and is checked as such. The decoder refuses a code whose decode doesn't re-encode to itself (rule 6), and the encoder iterates to a canonical code. (a) fails on f32 near-ties, because the decoded `CFrame` is f32; (b) lets error grow per relay hop. Cost: one more encode per decoded rotation. Verification and error re-measurement go to milestone 1 (`v5.md` §3.3, `m1-plan.md` §6.1). |
| 14 | `t.vector3` bounds that aren't f32 values | changed | A one-f32-spacing tolerance at the bounds, mapping to the end code, so any bounds work. Also a rule the item didn't ask for: `step` must exceed the f32 spacing at the largest bound (`vectorStep`), without which interior codes can't round-trip through a `Vector3` either (e.g. `t.vector3(-1e6, 1e6, 0.01)`). Requiring f32-exact bounds was not chosen: it would refuse ordinary bounds such as 0.1 without making anything more precise. |
| 15 | Refusal path root hard-wired to `data` | accepted | A `root` parameter (`m1-plan.md` §6.2). |
| 16 | Instance count from `#instances` | accepted | The count comes from the chunk header; the chunk addresses the frame's array by offset, so nil entries are safe. |
| 17 | No channel for `unresolved` | changed | Beyond a channel: a caller-provided `misses` list, which allocates only when a row is unresolved. The server reports the existing fact `unresolved`, its `value` now defined. A client counts `unresolvedMessages` and raises no fact, since streaming makes nil instances routine and the server is trusted (`v5.md` §7.3, §7.4). |
| 18 | Rule 9 checked per run | accepted | `beginChunk`/`endChunk` around rows with prefixes (`m1-plan.md` §6.2). |

---

# Draft 3.2 to 3.3

2026-10-15. Applies `.data/docs/reviews/m1-code.md` (`[review-m1 …]`), a review of the milestone 1 code. The code
fixes are listed in `m1-plan.md` §7, with an owning unit and a proof each. `m2-plan.md` §3.1 now starts from them.

**Count:** 24 findings. Accepted 23, changed 1, rejected 0.

| Id | Title | Outcome | Reason |
|---|---|---|---|
| B1 | A few bytes decode into millions of tables | changed | The review's fixes are adopted, but the per-frame budget is not proportional to frame bytes. Honest constant columns reach about 21,845 elements per byte, so a byte ratio either admits the attack or refuses honest data; the v5 attempt's "1024 B per frame byte + 16 KiB" fails the same way. Instead: `zeroWidthElement` and `elementsTooMany` (W ≤ 65,536) at declaration, and a per-player server bucket `inbound.elements` (20,000/s, burst 65,536) whose allowance is charged before allocation (rule 10, reported as `overBudget`). Clients don't enforce it, since the server is trusted and its compression must not be refused (`v5.md` §3.4, §4.8, §6.1, §7.3, §7.5; `m1-plan.md` A1, B1, C5). |
| M1 | `t.number` top code decodes to a value its encoder refuses | accepted | Decode clamps to `max` (§3.3). A clamp is the general fix: it covers every case where float stepping overshoots `max`, and the bottom code is already exact. |
| M2 | `t.direction` accepts non-canonical fold-edge codes | accepted | Canonical = fixed point of E, checked by the decoder (rule 6), as for rotation. Closed-form edge rules were not used, because they would be a second definition of the same set. §3.3's "idempotent by construction" now names exactly which quantizers are, and which are checked. |
| M3 | Optionals give second encodings and dropped pairs | accepted | `optionalPlacement` refuses an optional directly inside an optional, as an array element or as a map value. The review's alternative for arrays (count = the highest present index) was not chosen: it needs a scan of the table's keys on every encode, and Luau arrays with holes have no defined length. |
| M4 | Instance lists sized with `#list` | accepted | §6.2's `Chunk` with an explicit count, now (C1). |
| M5 | Encoding without `collect` produces refused bytes | accepted | The encode is read-only on the list, with a count fixed at collection; an unlisted instance is `internal` (C2). |
| M6 | Partial rollback | accepted | One `pcall` on the public encode entry points, which reset bits, tail and instance entries (C4). The cost is about 20–30 ns per encode on success, paid at `fire` time; leaving the writer poisoned was not chosen, because one throwing `t.convert` would corrupt every later message of the flush. |
| M7 | EG decode 84–105 ns against 35–58 | accepted | A batched reader (A4); §4.3 now cites the measured 53 ns interpreted and 22 ns native. |
| M8 | `Run.collect` encodes twice | accepted | A visitor over instance leaves only (C3). |
| M9 | Idempotence tests missing | accepted | Exhaustive quantizer specs (A5) and a canonical re-encode property on single rows (C8). |
| m1 | Rotation decode builds every `CFrame` twice | accepted | C9. |
| m2 | Two calls per field | accepted | A7. |
| m3 | Loose IR types | accepted | B2, C11. |
| m4 | A `_value` field infers as a codec | accepted | The brand becomes `["[Lync] value"]` (§3.3, B3). |
| m5 | Duplicated helpers | accepted | `src/wire/limits.luau` (A6), used by B4 and C13. |
| m6 | Open dispatch chains | accepted | `never` closures and `Complete` tables (B5, C10). |
| m7 | `show` prints 17 digits | accepted | B6. |
| m8 | Prefix without separator | accepted | B7. |
| m9 | Size and bench checks rest on models | accepted | B11, A9, C9. |
| t1 | Single-caller parameters | accepted | A8, B4, C12. |
| t2 | `Fail` drops `got nil` | accepted | `Fail.NONE` (B8); §7.1's grammar has the clause unconditionally. |
| t3 | Two conventions for options a kind doesn't take | accepted | nil throughout (B9); serialization is unchanged, and G6 holds. |
| t4 | Public types leak `any`; `Target` incomplete | accepted | `CustomSpec` uses `Bits` types (B10); `Target`'s groups belong to milestone 2's unit F. |
| t5 | §4.8 names only mode and k as free | accepted | Base and width are named too (§4.8). |

**Routing.** Unit E is editing `src/diag/` for milestone 2, so B's diag changes touch only `fail.luau`. The three
new codes are appended to `codes.luau` and `docs/codes/` after E's changes land.

# Draft 3.3 to 3.4 (build findings folded in)

2026-10-15. Milestones 1 and 2 were built to commit `f1fbfd7`, measured, and the code removed at the author's
request. This revision moves everything the build learned into the design and research, so nothing lives only in
deleted code or the build plans. Sources: `m1-plan.md` §6–§7, `m2-plan.md` §9, `reviews/m1-code.md`, this log's
3.1–3.3 sections, and the build's sources and benchmark data at `f1fbfd7` (copied evidence in `probes/build/`). No
review findings are triaged here; no product decision changes.

**Folded into `v5.md`.**

| Section | What the build established |
|---|---|
| header | Milestones 1–2 built, measured, removed; code at `f1fbfd7`, data in `probes/build/`. |
| §3.2 | Typing facts: `{ read from }`; side selection by `index<…>` (a type-function selector crashed luau-analyze, exit 139); brand `["[Lync] value"]`; the old solver rejects type functions and `read` fields, so the module is `--!nocheck`; exhaustiveness checked by a kind-coverage test, since `never` is unusable on the old solver. |
| §3.3 | `t.number` decode clamp; canonical rotation (fixed point or lower 2-cycle member) with checked decode at 2.2–2.7× (1.09 vs 0.43 µs interpreted, 0.36 vs 0.13 native); canonical direction with fold-edge rates; `t.vector3` f32 rule and `vectorStep`; `optionalPlacement`. |
| §4.1 | Split counting charges each frame kind's longest header (five kinds; up to about 5 B early). |
| §4.2 | Collect visitor at 3.4% of encode; unlisted instance raises `internal`; committed-count rule; decoders take the chunk count from the header; instance array always the second argument; rollback by one `pcall` at 0.1–0.3 µs per encode. |
| §4.3 | `columnMinRows` = 3 with its table; exactness to 2^53 (first-row residual as a difference, decode wraps before adding) and the bug that broke it; k search measured at 2.2–2.6× a k = 0 encode (1.0–1.4× on constant and sparse columns), so no fallback; batched EG-0 decode at 43–47 ns interpreted and 23–29 ns native against 86–94 per value. |
| §4.4 | `Seq.extend` range 2047 behind to 2048 ahead; counters start at 0 and are never negative. |
| §4.5 | HalfSipHash-1-3 at 1.8–3.5 µs (interpreted) and 0.26–0.42 µs (native) per 64 B; 22–24 and 3.1–3.7 µs per 1024 B. |
| §4.6 | Control counts charged to the element budget; `HELLO` name outside 1–64 is rule 2; `WELCOME` index 0, `stateRate` outside 10–60, cover over 16,384 or a non-finite epoch is rule 3; `REKEY` row is two u32. |
| §4.8, §4.9 | Decode amplification's two-part bound; client allowance 4,194,304. |
| §4.10 | Golden vectors G10, G11 and PERM in full; the `Q-*` quantizer vectors are in `probes/build/golden/`. |
| §7.1 | Code registry page format with byte-exact examples; deferral of codes raised by unbuilt units (the build's `RAISED_BY_UNIT_F` list); the build's 50 codes by family. |
| §7.3 | Fact key (player, reason, namespace, definition); `os.clock` windows; caps windowed per player; one record feeds counter and console; `Fact` frozen. |
| §7.4 | Counter names as field plus qualifier; console windows; summary counts the first occurrence. |
| §9 | Simulated network parameters (latency 0.05, jitter 0.02, loss 0.05, burst {0,1}, duplicate 0, stall {0.05, 0.3}, fps 60, unreliableLimit 1000); rates checked within 0.01 absolute; heavy specs behind an environment switch. |

**Superseded figures.** The 3.2→3.3 rows above quoted estimates the build then measured: rollback (M6) costs
0.1–0.3 µs per encode, not 20–30 ns; batched EG-0 decode (M7) is 43–47 ns interpreted and 23–29 ns native, not 53
and 22. `v5.md` carries the measured figures.

**Research annotations,** each marked "verified (milestone build, f1fbfd7)" in place, with the figure:

- `compression.md`: EG LUT row (batched figures); k-search cost; rotation worst case after the §4.4 table;
  direction errors 0.2369° and 0.05924°; fold-edge rates.
- `client-security.md` §3.1: HalfSipHash about 23 ns per byte interpreted, 3 ns native.
- `landscape.md` §3.3: the typing findings.
- `client-security-build.md` §1.2: Lune requires, `@lune/roblox` datatypes, Roblox globals injected by
  `getfenv(0)`, selene std not generable behind the proxy.
- `diagnostics.md`: §6.4 the luau-analyze crash; §9 rollback cost and the byte-exact registry.

**Plans kept as records.** `m1-plan.md` and `m2-plan.md` each open with a record header: built to `f1fbfd7`,
removed, folded into `v5.md` draft 3.4. Their bodies are unchanged.

**Citations.** References in the design to deleted source files now read `f1fbfd7:<path>`; measured data is cited
from `probes/build/`.

---

# Draft 3.4 to 3.5

2026-10-15. Applies `.data/docs/reviews/simplifications.md` (findings #1–#26 and its six vague refusal reasons,
here R1–R6), and the author's direction that performance is a cost to weigh, never a veto, for security (part 2).
New probe: `probes/design-3.5/golden_tag32.luau` (`.out`), the golden set with a 32-bit tag.

**Count, part 1:** 26 findings. Accepted 15, changed 11, rejected 0. The six vague refusal reasons: restated 6
(R2 also re-judged in part 2). **Part 2:** 19 security items re-judged: adopted or widened 7, still refused or kept
12.

## Root causes, fixed once

| Root cause | Findings | Fix, and where |
|---|---|---|
| A. "Honest" judging a player | #1, #5, #25 | "Unmodified client" defined in `v5.md` §1 and used everywhere; the fact tables' column is "Known causes on an unmodified client" (`v5.md` §7.3, `v5-integrity.md` §10); registry fix lines follow a rule (`v5.md` §7.1); test names and the network model renamed (`v5.md` §9); the plan records name the superseded terms in their headers. |
| B. A word list in place of the rule | #2, #11, #25 | The rule in `v5.md` §7.1, applied to code, evidence and counter names, messages, registry pages and docs; the lint is its backstop. |
| C. Facts named by action or channel | #3, #6, #10, #11, #18, #20 | One reason, or one evidence value, per trigger whose cause or knob differs: `overBudget` → three reasons, `clientReport` → three, `configInvalid` → five, `sendDropped` gains `cause`, outcome `limited`, the family sentence says "primary channel". |
| D. Option tables without cost | #7, #8, #13, #15 | Every options table has Type, Unit, Range, Default and Cost (`v5.md` §3.4, §7.5; `v5-integrity.md` §2, §4, §6–§9); integer/real stated; every constant in one split table (`v5.md` §4.9). |
| E. Research labels without definitions | #9, #12, #14 | `"release"` defined; the beacon gate is two options; `rawRemote` and `solverOff` have exact triggers (`v5-tooling.md` §3). |
| F. Causes written from memory | #4, #5, #19 | Each fact's causes derived from its trigger's documented failure modes, with the condition under which "none" holds; `v5.md` §9 runs every listed cause. |

## Findings

| # | Title | Outcome | Reason |
|---|---|---|---|
| 1 | "Honest" is an undefined label | accepted | The review's definition, in `v5.md` §1, plus "modified client" for the rest. `Net.HONEST` → `Net.DEFAULT`; tests named by origin (`v5.md` §9); the registry fix-line rule replaces the deleted pages' wording (`v5.md` §7.1). |
| 2 | The judging-word rule is a six-word list | changed | The rule as proposed, extended to counter names and the published docs and to "trustworthiness or skill" and "consequence". The lint list differs in two words: `flagged` rather than `flag*`, since "flag" names `t.rotation`'s axis bit; `honest*` banned outright, since no page needs it once the column is renamed. |
| 3 | `overBudget` merges three budgets | changed | Split into `overFrameBudget`, `overByteBudget` and `overElementBudget`, the review's alternative, on the coordinator's direction and root cause C: three triggers with three knobs. Evidence per reason: `tokens` where the bucket's level carries a fact (bytes), `allowance` and `elements` for rule 10; not for frames, where the level is always below 1. |
| 4 | "Known causes" contradict the design | changed | `tagMismatch`: the 5-raise cause, plus 6,144 consecutive unreliable losses (the seq extension and its retries). `desync`: the `tagMismatch` causes, 8 in a row; reconnect behaviour added to `v5.md` §10. `schemaMismatch`: the late-first-use cause listed, and the requirement stated in §4.6; the trigger is not changed, because answers go in `HELLO` order and a longer hold delays every later answer. `slotConflict`: "none while stalls are shorter than `timeout` and no frame is dropped whole", since each case needs two timeouts on one slot. `repeatedHello`, `impossibleAck`: "none" with the argument, `impossibleAck` bounded at 2048 lost state frames. |
| 5 | Milestone 5 facts lack causes; one says "never" | changed | `unreachable`: the scan widened to every `LocalScript` and `RunContext = Client` `Script` wherever stored (checked: `BaseScript.RunContext`, `Enum.RunContext.Client`, Roblox API dump 0.741.19) and to `check.clientRoots`; the remaining cause, a cloned `ModuleScript` outside the scan, is listed. Declared-trap, `canaryEchoed` and `clockRate` causes added (`v5-integrity.md` §10); `clockRate`'s now hold because its default threshold moved (#12). |
| 6 | `clientReport` merges three counts | changed | `reportedIdentity`, `reportedSourceUnlisted`, `reportedRefusedFrames`, marked client-stated. The count field is `reported`, not `count`, which is already the `Fact`'s coalescing count. |
| 7 | Schema options: no cost, open ranges, `burst` escapes | changed | Cost column for every option; `limit.perSecond` (0, 1000]; `burst` defaults to min(1000, max(1, ⌈perSecond⌉)); `reliableRate` real. `priority` is real on 0.001–1000, not (0, 1e6]: a 10^6 ratio between extremes is already more than age in ticks can express. |
| 8 | `configure`: blank costs, wire-contradicting types | changed | `state.rate` integer; bucket fields typed (perSecond real, burst integer); every burst bounded, unreliable bytes from 1,000; every cost cell filled or "unmeasured" with its milestone. `tag.cover`'s per-byte cost uses the build's 1024 B figures (0.022 µs/B interpreted, 0.0035 native) rather than the review's 64 B derivation, which includes per-call overhead; 0 defined. |
| 9 | `build.seed = "release"` undefined | changed | Defined (`v5-integrity.md` §2): one seed per build run, for every namespace and both sides, written to the manifest and shard headers; drawn from a clock-seeded generator, since the seed is public (every shard and `HELLO` carries it) and only has to differ between builds. Shards from different runs give `schemaMismatch` (`seedDiffers`). Kept rather than deleted (option b): it is also the plugin's "Prepare release", and it is now the default (part 2). |
| 10 | `rejected` and `unanswered` merge causes | changed | Outcome 3 is `limited` (over the server `limit`), which reveals nothing the client doesn't know. `rejected` stays merged on purpose, now stated: a trap must look like a `validate` refusal. "Returned nothing" is a reply the codec refuses, reported natively as `valueRefused` and answered `unanswered`, so no `handlerReturnedNil` code is needed (`v5.md` §3.5, §5.2). |
| 11 | `configInvalid` | accepted | Split into `configSyntax`, `configUnknownKey`, `configType`, `configRange`, `configMissing`, following the declaration codes (`v5-tooling.md` §3). |
| 12 | `clockRate`'s fixed gate | changed | Option (b): `clock.reportSlope` (0.001–1, default 0.01) and `clock.reportFits` (1–12, default 3). The default sits above the unmodified maximum (0.6% slew plus 0.03–0.08% fit noise) instead of at it. Option (a)'s per-fit counter is not added: the option at 0.001 already gives the game nearly every fit, and two ways to read slopes would break principle 4. `fits` is the run length so far, so it isn't constant (#24). Constants listed (#13). |
| 13 | Constants outside the table | accepted | One table in two parts, protocol and runtime, each row with a derivation or "chosen, unmeasured" (`v5.md` §4.9). "(draft value 4)" was already gone in 3.4. |
| 14 | `rawRemotes`, `solverOff` lack triggers | accepted | Triggers and evidence as proposed (`v5-tooling.md` §3, `v5.md` §3.2). `rawRemote` keeps `"warn"` by stated effect: Lync's inbound pipeline doesn't cover those remotes. |
| 15 | Integrity tables: type and cost | accepted | `clock.beacon` integer tenths, 0 or 5–15; Cost columns everywhere in `v5-integrity.md`. |
| 16 | "Once per window" names no key | accepted | One native report per (code, definition) per `observe.window` s from that key's previous report (`v5.md` §7.2), listed as a runtime constant. |
| 17 | `missedFlush` "once"; `frames` counts steps | accepted | Once per wait, at the 3rd step; evidence `steps`. |
| 18 | `sendDropped` `queue` | changed | `cause` 1–4 as proposed; `lane` dropped rather than kept, since `cause` determines it and a field that is a function of another carries no fact (#24's rule). |
| 19 | Causes as vague quantities | accepted | Each restated in tokens, seconds or sequence numbers (`v5.md` §7.3). |
| 20 | Families and two-channel codes | accepted | "A family fixes the primary channel", the two second channels named; `schemaMismatch` out of the `fault` list. |
| 21 | Vague quantities | accepted | Each replaced: the no-build path's 3.2–4.6x / 4.2x; the compression threshold assumption; the level spread; the busy model's rates; 8.5 acks per state frame; the walk's 133–492 ns; snapshot cost "unmeasured, milestone 2" (no figure exists); the beacon's exact bits; scan cost "milestone 5"; the benchmark by name, columns and target. The extensions' cell figure keeps its citation. |
| 22 | Extensions read as specification | accepted | "Unspecified until milestone 7" for each unvalued option; `rewind` returns state and the game decides the hit; jitter's estimator named, its window left to milestone 7. |
| 23 | Every fact at warning severity | accepted | Option 1: kept and stated, with the reason (the Error Report collects warnings, not prints). |
| 24 | Constant evidence fields | accepted | `desync`'s `failures` → `sinceRekey` (−1 when none, since evidence is numbers only); `remotesMissing` has no evidence. |
| 25 | Threat vocabulary | accepted | "Modified client", "API drivers running at identity 8 under an unlisted chunk name", "a raw-state reader"; test names by rule (`v5.md` §9). |
| 26 | Behaviour words | accepted | Each replaced. The seam sentence now states the mechanism (bound at start, no nil test) and that its cost is unmeasured, rather than "compiles out". |

## Vague refusal reasons, restated

| # | Item | Outcome | Stated reason |
|---|---|---|---|
| R1 | `rans`, the unreliable-event deadline, `:initial()`, the roblox-ts transformer, compiler plugins | accepted | `rans`: 2–10% best gain for 106 ns per symbol interpreted (2–3x the EG decode) and a trained-table artefact keyed by the schema hash `[compression §6.3]`. Deadline: nothing holds an unreliable event past the next flush (§5.3 and §5.4 drop rather than hold), so a deadline never fires. `:initial()`: a reliable field never written after its add already costs bits only in the add. Transformer: a second schema front end (principle 4); its TS-only checks run, less precisely, over `rbxtsc`'s Luau `[client-security-build §1.7]`. Compiler plugins: a public IR and codegen API to keep stable, with no consumer, since every listed extension uses `v5.md` §8's seams. |
| R2 | Low-order watermarks | accepted | Re-judged in part 2 (below). |
| R3 | A Studio line on runtime-path start | accepted | The reason is that Lync can't tell which solver is on, so the line would print in every runtime-path session, new solver included. The prediction about ignored output is withdrawn. |
| R4 | Holding later messages behind a held one | accepted | The stall is up to `burst`/`perSecond` seconds (10 s at `perSecond` = 0.1), not "up to a second". |
| R5 | SARIF | accepted | Cost stated: a fourth renderer and its golden tests, for a consumer the `github` format covers in Actions; added on a user's need (`v5-tooling.md` §3). |
| R6 | Lute | accepted | The missing criteria from the brief: no macOS x86_64 release binary, and module paths that disagree with its own definitions (`v5-tooling.md` §4). |

## Part 2: security cost re-judged

Principle 2 now says it (`v5.md` §1, §6.2; `v5-integrity.md` §1): cost is stated and weighed, and where it matters
an option controls it; it never refuses a security measure by itself.

| Item | Earlier reason | New verdict | Cost accepted |
|---|---|---|---|
| Tag width 16 bits | 2 B; "32 bits only matters if acceptance were treated as authentication" `[client-security §3.1]` | **32 bits** (`v5.md` §4.5) | 2 B more per upstream frame, 140 B/s for the busy model; no CPU (the hash's natural output). A keyless sender at the default budgets passes once per about 50 s at 16 bits and once per about 38 days at 32; Lync applies no consequence, so the width must bound it. G4, G5, G8 gain two bytes. |
| `tag.cover` default 1024 B | tag CPU per covered byte | **default 16,384** (every frame byte) | ≤ 0.23 ms/s per player on the server at the default byte budgets; about 0.022 µs/B on the client. Bytes past 1024 of a large frame could be edited below the encoder without failing the tag. |
| Caller probe sampled, 1 in 20, ≤ 10/s | draft 2 decision 9: one failing `pcall` per probe | **every call, ≤ 60/s** (`v5-integrity.md` §4) | ≤ 0.2 ms of client CPU a second. If Studio shows a caught capability failure is logged, the default returns to sampling, for that reason, not cost. |
| Clock beacon off by default | unmeasured noise, not cost; "about 4 B per beacon" | **on, 1 s,** with the gate as two options (#12) | ≤ 3 B/s per player up; one 66-slope fit per 5 s per player (unmeasured). The beacon rides frames the client sends anyway. |
| Build seed default 0 (rotation off) | none recorded | **default `"release"`** (`v5-integrity.md` §2) | none at run time or on the wire; every build changes every shard's bytes, and client and server shards must come from one build run. |
| Canary whole-value match | review-2 m3: exact match only | **scan up to `canary.scanBytes`, default 256** (`v5-integrity.md` §9) | up to `scanBytes` − 11 lookups per longer inbound value (per-offset cost measured in milestone 5). Finds a canary pasted into chat. |
| Decoys `maxPerViewer` 1–16 | per-viewer re-encode and pool slots | **range 1–256** | each decoy takes a pool slot out of `maxRecords` and its bytes per viewer; the game chooses. |
| Downstream tags, client replay window | own view only; a PRF per recipient, ≤ 3% of a core; ends `FireAllClients` | still refused | Cost is not the reason: no third party can write a client's downstream (the engine's transport carries it), so they protect only a modified client's view from itself; the refused-frame report covers non-canonical injection. |
| Masking or whitening frames | +62–272% bytes after zstd; stops nothing above the wire | still refused | Cost is not the reason: everything it would hide, a reader gets with less work by requiring the client shard and connecting to its signals, so it prices no reader; every forge it would block, the tag blocks. Cost stated: about 0 B for the bit section, CPU per byte at the tag's rate, +62–272% if the tail is masked. |
| Per-session upstream id shuffle | marginal over the tag and permutation | still out | Its per-session read is the tag key's read, in the same pass, so it adds no recurring work. Cost: a decode table per player (about 20,000 slots for 200 definitions × 100 players). |
| Runtime field shuffling | 2–3x slower per record write | still out | Re-judged on protection: a forger who reads the per-session key reads a per-session order in the same pass, and rotation already varies order per build. Cost stated: 2–3x per record write. |
| Codecs scattered into game scripts | 5.0x bytecode, developer cost | still refused | Correctness and an author decision, not cost: rewriting the developer's scripts each build (merge conflicts, `UpdateSourceAsync` races) and removing the typed shard API, which the author made primary. |
| Per-player shard variants | join-time dependency | still refused | A rotation-aware tool already reads its variant's constants from the loaded shard, so no work is added. |
| Low-order watermarks (R2) | "weak; visible jitter" | still refused | One rounding to twice the step strips the mark with no per-build work, so it prices nothing; and it moves values past the declared step/2 error, breaking §3.3's precision. Cost: per-viewer encoding. |
| Obfuscation, VMs, `getfenv`/`setfenv`, `loadstring` | Creator Store; fast calls | still refused | The Creator Store rule, a platform constraint, not the deoptimisation. |
| Hook and environment checks | standard tools pass them | still refused | Unchanged: they price nothing, at any cost. |
| `REPORT` never forces a frame | bytes | kept | Forcing adds no protection: a patched Lync suppresses `REPORT` either way, and counts ride the next frame the client sends. |
| `REKEY` at most once per 60 s | traffic | kept | A rekey restores a desynced client; more frequent rekeys add no protection, since the key is already per session. |
| Per-viewer slot permutation | keys travel in adds | refused | Unchanged: comparing key sets finds what it hides. |

## Decisions made in 3.5

1. **Downstream frames split before 4,194,304 elements** (`v5.md` §4.1), found while deriving
   `reportedRefusedFrames`' causes: without it, constant columns let an unmodified server write a frame its clients
   refuse by rule 10.
2. **`limited`**, the sixth outcome code, on the spare outcome value 3.
3. **A client counter `refusedFrames`** (`v5.md` §7.4), which `REPORT` already sends.
4. **The `HELLO` hold stays 10 s,** with the requirement stated, because answers are ordered.
5. **`check.clientRoots`** in `lync.toml`, so a game can list where cloned client modules live.
6. **The beacon never forces a frame;** an idle gap over 3 × `clock.beacon` restarts the estimate.
7. **Clock defaults:** beacon 1 s, `reportSlope` 0.01, `reportFits` 3.
8. **`callerProbe.maxPerSecond` 1–63,** the full u6.
9. **Evidence names:** `reported` for client-stated counts; `sinceRekey` −1 when no `REKEY` was sent.
10. **Codes of milestones 1–2:** 53 (`v5.md` §7.1).
