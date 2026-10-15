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

**`columnMinRows` benchmark** (unit C, `bench/rows.luau`): bits of n single rows against one column block, summed
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
