# Review: Lync v5 design draft 2, redundancy and inefficiency

Reviewed: `.data/docs/design/v5.md` draft 2 (2026-10-15) and its change log, `.data/docs/design/v5-changes.md`.
The author's final decisions are taken as given:
- facts, not verdicts;
- client-side integrity is first-class, judged by the tamper cost it imposes against its own cost;
- per-build rotation and the per-server permutation stay.

Nothing below argues against those decisions. Where a finding touches rotation or the client measures, it is
about duplicated knobs, duplicated reports or bytes, not about whether the measure should exist.

Scope as before: redundancy and inefficiency only. Draft-1 findings are cited as R1–R20
(`v5-design-1-redundancy.md`).

Probes are in `.data/docs/probes/review-redundancy-2/`, with raw output in the `.out` file beside each:

| Probe | Settles |
|---|---|
| `newest_rows.luau` | `:newest()` rows copied as byte-aligned chunks against bit-packed per viewer |
| `inbound_hotpath.luau` | per-message and per-frame cost of what draft 2 added inbound, plus caller-probe sampling, the replay window and the permutation build |
| `integrity_state.luau` | canary state memory, decoy behaviour cost, 12-bit serial comparison on stored row sequences |
| `wire_overhead_2.py` | draft-2 framing bytes, including ack-only frames; ack batching; id widths |

Luau timings come from the Luau 0.740 CLI at `-O2`, interpreted (the client case) and `--codegen` (the server
case), on a shared 2.1 GHz Xeon, as the median of 7 runs. CLI timings don't transfer exactly to Roblox, and Roblox
call costs (`FireClient`, `GetNetworkPing`, capability errors) can't be measured here.

## Summary

| # | Finding | Severity | Cost |
|---|---|---|---|
| 1 | Rows are ordered by comparing a stored per-record 12-bit sequence | **blocking** | after ≥2048 frames idle (34 s at 60 Hz, 102 s at 20 Hz), up to 2048 frames of a record's rows are dropped, while the server's acks say they were delivered |
| 2 | The join hold cap equals the inbound byte burst, and framing pushes it over | major | an honest client's last held frame is dropped as `overBudget` at the defaults; any `burst` below 65,536 drops more |
| 3 | Per-player downstream sequences and tick deltas make broadcast frames per-player | major | unreliable broadcasts never use `FireAllClients`; reliable ones only when every recipient shares a previous tick |
| 4 | An ack-only frame for every owed ack | minor | idle players send 20–60 upstream calls/s (154–461 B/s), against draft 1's 10 calls/s (129 B/s) |
| 5 | `trap` and `unreachable` report the same fact, and `callerSource` repeats it | minor | three reasons for one fact; probes spent on definitions already reported |
| 6 | 31 anomaly reasons where 21 keep every fact | minor | |
| 7 | Knobs that should be protocol constants, and settings reachable two ways | minor | 9 knobs with no user, and 4 pairs that say the same thing |
| 8 | `REPORT` is sent for probe counts alone | minor | an honest client sends up to 10 reports/s that carry no anomaly |
| 9 | Canary state is kept per player, and buffer lookups allocate | minor | 3.2 MB against 47 KB for 100 × 1024; 80 ns and an allocation against 13 ns per inbound buffer |
| 10 | One id space for both directions and both request roles | minor | 1 bit per run in typical schemas, plus a reason (`wrongDirection`) the layout could make impossible |
| 11 | Generation bits on the ordered lane | minor | 2 bits per reliable single-row update and per remove, for nothing |
| 12 | Unspecified framing and ordering details | minor | principle 5 |
| 13–15 | Error-channel split, the downstream unreliable tick width, `WELCOME` repeated per namespace | taste | |

**Draft-1 findings:**
- **Fixed:** 15 of 20 (R1, R3, R5, R6, R8–R16, R18–R20). R5 has an idle-case regression (finding 4), and R10
  leaves one ordering detail open (finding 12).
- **Moved to extensions:** R2 and R4.
- **Kept by the author:** R7.
- **Changed with a sound reason:** R16 and R17.

The fixes for R1 and R5, which I proposed, are the source of finding 3. The fix for R19 (ring sizing) is right,
but the row-ordering rule next to it is finding 1.

---

## Part A. Were the draft-1 findings fixed as claimed?

| Id | Claimed fix (draft 2) | Verdict | Evidence |
|---|---|---|---|
| R1 ack keyed by tick | 12-bit downstream unreliable `seq`, acked with 16 bits (§4.1, §5.3) | **fixed**, but see finding 3 | the layout identifies every downstream unreliable frame |
| R2 no input ack | `inputs` extension; the upstream seq doubles as input index, carried downstream (§7.2) | **moved**; fine for the core | the extension must add a downstream header field; specify it with the extension |
| R3 `:newest()` encoded once and predicted | absolute byte-aligned rows, copied per viewer; prediction moved to `acked` (§5.3) | **fixed, numbers verified** | `newest_layout.out` matches the table (350/331 B shooter, 5.7% padding; 248.7/230 B mmo, 8.1%). My probe confirms the CPU half: copying a 12 B row costs 27.6 ns native per viewer-row, against 41.1 ns to bit-pack the same row per viewer (interpreted 68.5 against 344 ns). Encode-once plus copy is the faster option, and its 5.4–8% byte cost is honest (`newest_rows.out`) |
| R4 per-connection interning | the `strings` extension, per-audience tables, second sight (§4.5) | **moved** | |
| R5 header repeats the tick and the ack | no upstream tick; the ack once, when new; tick delta downstream (§4.1) | **fixed for busy players; idle regressed** (finding 4) | draft-2 layout, padding included: busy up 374 B/s, down 160 B/s, against the claimed 353/130 (the difference is byte padding, which the claim omits). Idle up is 154 B/s at 20 calls/s against draft 1's 129 B/s at 10 calls/s (`wire_overhead_2.out`) |
| R6 section `kind` + `length` | per-list EG-0 counts, no skipping, tail written backwards (§4.1, §6.1) | **fixed** | 1 bit per empty list |
| R7 per-build rotation | kept (author) | **out of scope by decision** | the knob duplication remains: finding 7 |
| R8 four rejection hooks, two rate limiters | middleware deleted; `validate` the one hook; `cooldown` folded into `limit` (§6.1, §7.1) | **fixed** | |
| R9 event `newest` | deleted; singleton collections (§3.4) | **fixed** | |
| R10 per-tick accumulators and the bucket pass | per-collection FIFOs merged by `priority` × age (§5.4) | **fixed**; one detail open | where a re-pended record (lost frame) goes in its FIFO is unspecified: finding 12 |
| R11 priority and rate twice; `:owner()` three ways | `priority` on collections only; `:maxHz` and `owner` in `interest` | **fixed** | |
| R12 oversize handled three ways | planner refusal only | **fixed** | |
| R13 four artefacts, two generators | `manifest.json` + `report.md`; one writer | **fixed** | |
| R14 traps declared two ways | `:trap()` only | **fixed**; a new overlap with reachability: finding 5 | |
| R15 `timestamped` 8 bits per event | deleted | **fixed** | |
| R16 explicit u16 request ids | 4-bit slots plus a 2-bit outcome, explicit (§5.6) | **changed, reason sound** | the two ends free a slot at different times, so implicit numbering could disagree. Accepted |
| R17 handshake per-definition hashes and seed | `HELLO` = version 8 + seed 32 + hash 64 bits = 13 B (§4.4) | **changed, sound** | the seed stays with rotation |
| R18 `get` clones | copy-on-write (§3.5) | **fixed** | the cost moves to row application on the client: 182 ns and 320 B per record per state tick for moving records (64 fighters at 20 Hz ≈ 0.23 ms/s and 410 KB/s of garbage, interpreted). Acceptable, but the doc should state it beside the `get` figure |
| R19 ring twice the ack window | 17 entries in a buffer (§5.3) | **fixed** | |
| R20 codec overlaps | all five applied (§3.3) | **fixed** | |

---

## Part B. Findings

### 1. Rows are ordered by comparing a stored per-record 12-bit sequence (blocking)

**Section.** §5.3, Repair: "the client applies a record's row only if its frame seq is newer (12-bit serial
arithmetic)".

**Case.** The client keeps, per record, the seq of the last row it applied, and compares each new row's frame
seq against it modulo 4096. Serial arithmetic is valid only while the two values are less than 2048 apart, but a
stored per-record value ages without bound.

Take a parked vehicle, or an AFK player whose `position:newest()` stops changing:
- at 60 downstream unreliable frames/s (unreliable events every flush), the stored seq is ≥2048 behind after
  34 s;
- at 20 frames/s, after 102 s.

When the record moves again, `(new − stored) mod 4096 ∈ [2048, 4095]`. The row compares as older and is
dropped. So is every following row, until the distance wraps past 4096: up to 2048 more frames, which is 34 s at
60 Hz (`integrity_state.out`: idle 2048, 3000 and 4095 → "DROPPED as older"; 5000 → applied).

The frames themselves were received, so the client's acks mark them delivered, and notify never resends. The
record stays frozen on screen while it moves on the server. This is the stuck-after-idle failure notify was
chosen to remove `[state-sync §1.7]`.

**Cost.** Correctness of `:newest()`, at zero bytes.

**Smallest fix.** The client extends each incoming 12-bit seq to a full counter relative to the newest frame seq
it has received, which is always fresh, and stores full values per record. The comparison then has no horizon.
No wire change. The same rule should be written down for any other stored 12-bit value.

### 2. The join hold cap equals the inbound byte burst, and framing pushes it over (major)

**Section.** §4.4 Joining ("holds reliable fires up to 65,536 encoded bytes"); §6.4 `inbound.reliable.bytes`
(default burst 65,536, range 1,024–1,048,576, "must be at least 16,384"); §6.1 step 2 (charge `buffer.len` +
8 B per instance; over-budget reliable frames are dropped).

**Case.** A client fires heavily during join, the documented honest cause of `holdFull`, and holds 65,536
encoded bytes. `WELCOME` arrives, and the client releases them as four 16,384 B frames. Each frame also carries
its ack bit, list counts, run headers and a 2 B tag, so the four frames total more than 65,536 B. The server's
bucket holds at most its burst of 65,536, so the fourth frame finds fewer tokens than its length.

That frame is dropped as `overBudget`, and it is still tag-checked, so the counter stays in step. Its messages are
lost without a `rejected`, so a request in it resolves only by `timeout` after 10 s. Any game that sets `burst`
below 65,536, which the range allows down to 1,024, drops held data from smaller holds too.

Two limits that must agree are set in two places: a client-side constant the client must apply before `WELCOME`,
and a server knob.

**Cost.** Honest client messages lost at the defaults, reported as an anomaly against the honest player.

**Smallest fix.** Tie them together:
- make the hold cap a protocol constant at most `burst − 4 × maxFrameOverhead`, for example 61,440;
- set the range minimum of `inbound.reliable.bytes.burst` to the hold cap plus that overhead.

Or exempt the first `WELCOME`-release burst from the byte bucket, charging it to its own one-shot allowance.

### 3. Per-player downstream sequences and tick deltas make broadcast frames per-player (major)

**Section.** §4.1: "When a flush has no content addressed to a subset of players, one frame goes to everyone
through `FireAllClients`". The header rules: `downstream unreliable := seq:12 tick:16` (seq per player, the ack
target) and `downstream reliable := tick: '0' same as previous reliable frame | '10' +1 | '11' u16`.

**Case.**
- **Unreliable.** `Net.vfx:fire(Lync.all, ...)` on the unreliable lane every frame. The run is encoded once, but
  every player's frame has its own `seq`, so the frames are never identical. 100 players means 100 `FireClient`
  calls per flush, always.
- **Reliable.** The delta is relative to *that player's* previous reliable frame. A player who received nothing
  in the flush where the tick last advanced needs `'11' u16`, while the others need `'10'`. The shared frame
  differs, and broadcast fails for that flush.
- **Decoys.** Their reliable sections are per-viewer by design, so any flush where a decoy's reliable fields
  change is per-player for every player with decoys.

**Cost.** The `FireAllClients` path that §4.1 promises is unreachable for unreliable broadcasts and fragile for
reliable ones. Lync-side, each lost broadcast costs a frame assembly (`buffer.copy` per piece) and a remote call
per player. The engine-side cost per `FireClient` is unmeasured (§11). R1's and R5's fixes, which I proposed,
introduced this.

**Smallest fix.**
- **Unreliable.** Number downstream unreliable frames with a *flush-global* sequence: every unreliable frame
  slot of a flush gets one value, shared by every player sent that slot. The server's per-player ring records
  which values it sent to that player. A `received` bit for a value never sent to that player stays
  `impossibleAck`. Gaps where nothing was sent are known to the server and never count as loss.
- **Reliable.** A broadcast frame uses the `'11' u16` form whenever its recipients' previous ticks differ:
  16 bits once, rather than N calls.

### 4. An ack-only frame for every owed ack (minor)

**Section.** §4.1: "When a flush has nothing else to send but owes an ack, the client sends an unreliable frame
holding only its header. There is no fixed-rate heartbeat."

**Case.** An idle player in a busy server owes an ack after every downstream unreliable frame. That is 20/s from
state-tick rows alone, and 60/s when the server fires unreliable events every frame.

Each ack-only frame is 7.7 B: seq, ack, an empty list and a tag. It also costs a remote call, a client tag of
about 1.3 µs interpreted, and a server tag check plus replay-window update. Draft 1's 10 Hz heartbeat was cheaper
in calls.

The 16-bit window doesn't need this rate. Acking every second owed frame still covers each frame 8.5 times.

**Cost** (`wire_overhead_2.out`):

| Downstream unreliable rate | Ack every frame (K=1) | K=2 | K=4 |
|---|---|---|---|
| 20/s | 160 B/s, 20 calls | 80 B/s, 10 calls, repair +50 ms | 40 B/s, 5 calls, repair +150 ms |
| 60/s | 480 B/s, 60 calls | 240 B/s, 30 calls, repair +17 ms | 120 B/s, 15 calls, repair +50 ms |

**Smallest fix.** An ack-only frame is owed once K new downstream unreliable frames are unacked, or once the
oldest unacked one is 100 ms old. K is a protocol constant (2). Acks riding on frames the client sends anyway are
unchanged.

### 5. `trap` and `unreachable` report the same fact, and `callerSource` repeats it (minor)

**Section.** §6.2.5, §6.2.6, §6.2.7, §6.3.

**Case.** A declared trap is, by construction, a client-sent definition that no honest client code references.
On the generated path, reachability already reports every such definition as `unreachable`.

What `:trap()` adds:
- an action (drop instead of deliver);
- a Studio print;
- coverage on the runtime path, where reachability doesn't exist.

The fact is the same: "a client-sent definition that client code doesn't fire arrived". The developer's
declaration is a property of the definition, not a different observation.

The caller probe's source check also uses the same build list. For an unreachable definition the list is empty,
so every probed call is `callerSource`-foreign. The client spends probes, and sends `REPORT` bytes, re-reporting
what the server already saw on every message, unsampled.

**Cost.** Two reasons and two code paths for one fact, plus wasted probes.

**Smallest fix.**
- Report one reason, `unreachable`, with evidence `declared` (0 or 1), action "dropped" when declared.
  `:trap()` stays as the declaration that makes the definition handler-less and droppable on both paths.
- Skip the source probe for definitions with an empty script list.

### 6. 31 anomaly reasons where 21 keep every fact (minor)

**Section.** §6.3 table.

Draft 2 already merged `Malformed` and `OutOfBounds` into `malformed` with a rule number. The same move applies
elsewhere, and in each merge below the action is identical and every fact survives as evidence:

| Merge | Into | Evidence that keeps the fact |
|---|---|---|
| `wrongDirection`, `wrongLane` | `malformed` rules 10, 11 (or impossible: finding 10) | `rule` |
| `duplicate`, `staleSeq` | `replayed` | `seq`, `behind`, `seen` (0/1) |
| `unknownEnum`, `instanceMissing`, `instanceClass` | `unresolved` | `what` (1 enum, 2 nil instance, 3 class), `value` |
| `trap`, `unreachable` | `unreachable` | `declared` (finding 5) |
| `callerIdentity`, `callerSource`, `clientRefusedFrame` | `clientReport` | `probes`, `elevated`, `foreign`, `refusedFrames` |
| `holdFull`, `limitQueueFull` | `sendDropped` | `queue` (1 hold, 2 limit), `bytes`/`burst` |

Two more are not facts about another player:
- `validateFalse` is a decision the game's own `validate` just made, and the game holds that fact already.
- `validatorError` is a game bug, which §3.8 surfaces with a native traceback for every other callback.

Keeping them in the anomaly stream gives game-code outcomes two channels. Removing them leaves the `rejected`
answer and the traceback.

That makes 31 → 21. The three `REPORT` reasons also come from one message: today one `REPORT` can emit three
events, and merged it emits one. Coalescing keys and the per-player cap (16) are then spent on distinct facts
rather than on fragments of one report.

### 7. Knobs that should be protocol constants, and settings reachable two ways (minor)

**Section.** §6.2 option tables, §6.4, §8.2.

**Knobs with no user** (no game has a reason to set them; each is a property of the transport or of Lync's own
implementation):

| Knob | Why it is a constant |
|---|---|
| `tagLookahead` (0–16) | honest gaps are 1, from `FireServer` raising; it changes failure-path CPU only |
| `desyncAfter` (2–64), `rekeyInterval` (10–600 s) | recovery from Lync's own counter bug or an engine reconnect |
| `replayWindow` (32–256) | a transport reorder depth (§11 measures it); also bounded by the 12-bit extension |
| `limitSlack` (0–10 s) | §11 says it is set by the measured RTO, which makes it a measured constant |
| `clockWindow`, `clockConfirm`, `clockRateLimit` | three tuning numbers for one detector whose fact is a slope. Report the fitted slope whenever it exceeds the platform's documented 0.6% contract, and the game applies its own threshold, as facts-not-verdicts asks |
| `inbound.*.frames` | §6.4 derives them from "one frame per flush plus splits": derived, not chosen |

**Settings reachable two ways:**

| Setting | First way | Second way |
|---|---|---|
| identity permutation | `permuteIds = false` | test seam with seed 0 (§6.2.3) |
| caller probe off | `callerProbe.share = 0` | `callerProbe.maxPerSecond = 0` |
| rotation off | `build.seed = 0` | `rotate.fields = false` with `rotate.tag = false` |
| hold cap and inbound burst | client constant | server knob (finding 2) |

- **Rotation.** A nonzero seed with both `rotate.*` false changes nothing at run time, but still refuses
  runtime-path clients through the `HELLO` seed. Rotation stays by the author's decision; the two `rotate.*`
  booleans are knobs without a stated user.
- **`tagCover`.** Its range of 0–65,535 exceeds the 16,384 B upstream frame cap, so values above it are
  undefined. Make the range 0–16,384.
- **`callerProbe.share`.** It is configured as a continuous 0–1 but travels in 1/255 steps (§4.4), so the
  effective share differs from the configured one.
- **Reachability and the source probe.** `check.reachability = false` also removes the script lists that the
  caller probe's source check reads. The doc doesn't say that this silently turns `callerSource` off.

**Smallest fix.** Move the first table to protocol constants, listed in one table, versioned by the protocol
version. Keep one off-switch per measure. Delete `permuteIds`, since the seam covers tests.

### 8. `REPORT` is sent for probe counts alone (minor)

**Section.** §4.4 ("sent in the next reliable frame after any count changes, at most once per flush"); §6.2.7.

**Case.** Every probe increments `probes`, so an honest client sends a `REPORT` after every probe: up to
`maxPerSecond` = 10 per second. Each carries `elevated = foreign = refused = 0`, so no anomaly results from any
of them. When the client has no other reliable frame in that flush, "next reliable frame" is either a forced
frame (a remote call, a tag and about 5 B) or undefined.

**Cost.** About 2 B riding, or about 5 B plus a call when forced, up to 10/s per honest player, all of it carrying
no fact. It also makes probes visible as upstream traffic.

**Smallest fix.** Send `REPORT` only when a non-`probes` count is nonzero, carrying `probes` since the previous
report as the denominator. Say that it never forces a frame.

### 9. Canary state is kept per player, and buffer lookups allocate (minor)

**Section.** §6.2.12: "Every inbound string or buffer value from a player is looked up among the canary values
sent to that player"; "one set entry per canary value a player was sent".

**Case.** Canary values are per record per server, the same for every viewer, yet the design keeps one set per
player. For 100 players and 1024 records, that is 3.2 MB at 32 B per entry. A server-wide `value → slot` map plus
a per-viewer "add sent" bitset holds the same facts in 47 KB (`integrity_state.out`).

Buffers compare by reference, so looking up an inbound `t.buffer` value needs `buffer.tostring`: an allocation of
up to `maxBytes`. That costs 80 ns native and 97 ns interpreted for 64 B, against 13 ns for a string
(`inbound_hotpath.out`). Every canary value is exactly min(16, maxBytes) long, so a length test first rejects
almost every inbound value with no allocation (13 ns).

**Smallest fix.** Use one server-wide map and a per-viewer bitset, and test length before converting.

### 10. One id space for both directions and both request roles (minor)

**Section.** §4.1: "every event and collection takes one, every request two (`ask`, `answer`) … Ids are
⌈log2(count + 1)⌉ bits".

**Case.** A receiver only ever decodes ids sent in one direction, yet every id carries the width of both
directions' definitions together. Collections appear only in the `states` and `removes` lists, yet they take run
ids. With per-direction numbering:
- the arena schema's runs drop from 3 to 2 bits each way, and its collection index from 3 to 1 bit;
- a 60-definition schema saves 1 bit per upstream run (`wire_overhead_2.out`).

`wrongDirection` then can't be expressed. An upstream id outside the upstream space is rule 7, `malformed`
(finding 6).

**Cost.** 1–2 bits per run and per collection section, on every frame.

**Smallest fix.** Use three spaces: upstream runs, downstream runs, and collection indices in the state lists.
The permutation applies per space.

### 11. Generation bits on the ordered lane (minor)

**Section.** §5.2 Records by slot: "Updates, removes and rows address a record by slot … plus a 2-bit
generation".

**Case.** On the reliable lane, adds, updates and removes arrive in order, so a slot always means its current
occupant. Only unreliable rows can arrive before their add or after their remove, so only they need the
generation.

**Cost.** 2 bits per single-row reliable update and per remove. In column-coded sections it is a near-free
zero-mode column.

**Smallest fix.** Put the generation on unreliable rows only.

### 12. Unspecified framing and ordering details (minor, principle 5)

- **Rows in unreliable frames.** `body, otherwise := runs … [newest rows on downstream unreliable state ticks]`.
  The client can't tell a state-tick frame from an event frame of the same tick after a loss, nor which
  collection a row group belongs to, nor where rows continue in a split. The rows need a count (EG-0, 1 bit when
  empty) and a collection index per group.
- **Re-pended records in the scheduler.** A record whose frame was lost "becomes pending again" (§5.3). §5.4's
  FIFOs are exact only if it is appended at the current tick, with its age restarting. Keeping its original age
  would need an ordered insert. Say which.

### 13–15. Taste

13. **Two channels for local game-code mistakes.** `validatorError`, `limitQueueFull`, `holdFull` and
    `missedFlush` are reported as anomalies, while every other callback error is a traceback and every other
    caller mistake throws (§3.8). That is two error models (principle 4). Keep anomalies for what other players
    send.
14. **The downstream unreliable `tick:16` could be 8 bits.** The client already computes T from `epoch` and
    `stateRate` in `WELCOME` (§5.1), so the header only needs to resolve network delay: ±128 ticks is ±6.4 s at
    20 Hz. Saves 8 bits per downstream unreliable frame.
15. **`WELCOME` repeats connection-global fields per namespace.** `epoch` (8 B) and `stateRate` come from one
    global `Lync.configure`, but every namespace's `WELCOME` carries them. Send them in the connection's first
    `WELCOME` only, as the integrity fields already are.

---

## Part C. The 12 client-side measures: cost, and which overlap

Per measure: wire bytes, CPU on each end, and state per player. "Measured" cites this review's probes or
draft 1's (`review-redundancy/`); "estimated" says so.

| § | Measure | Wire | Client CPU | Server CPU | State per player | Overlap |
|---|---|---|---|---|---|---|
| 6.2.1 | tag, rekey | 2 B per upstream frame, both lanes | 1.3 µs (16 B) – 3.2 µs (64 B) per frame, interpreted (measured) | 0.18–0.48 µs per frame, native (measured) | key, counter | none |
| 6.2.2 | seq + replay window | 1.5 B per upstream unreliable frame | the counter only | 24 ns native, 110 interpreted per frame (measured) | 64 bits | none: the tag's unreliable half |
| 6.2.3 | id permutation | 0 | build: 91 ns per id, interpreted, once (measured) | build: 21 ns per id, native, once (measured); one array index per id read (in the +16 ns below) | none (per server) | knob overlaps the test seam (finding 7) |
| 6.2.4 | field and tag rotation | 0 | 0 | 0 | none | knob overlaps (finding 7); author-kept |
| 6.2.5 | traps | 0; maybe 1 id bit | 0 | flag check per message | none | **same fact as 6.2.6** (finding 5) |
| 6.2.6 | reachability | 0 | 0 | one table index per message | none | **same fact as 6.2.5**; source probe repeats it |
| 6.2.7 | caller probe | `REPORT` ≈2–5 B, up to 10/s from honest clients (finding 8) | a random draw per fire, 24–32 ns (measured; a geometric countdown is 15–19 ns); ≤10 failing `pcall`s/s, 2.2–2.5 µs each in the CLI, consistent with the brief's 2.2–3.3 µs | `REPORT` handling | counts | source check overlaps 6.2.6 on unreferenced definitions |
| 6.2.8 | refused-frame report | `REPORT` only when it fires | 0 (decode is already strict) | 0 | count | none |
| 6.2.9 | clock beacon (off) | ≈4 B per beacon | one clock read | one 12-point Theil–Sen fit per 5 s | 12 minima | three tuning knobs (finding 7) |
| 6.2.10 | early answers | 0 | 0 | one clock and one `GetNetworkPing` read per server ask (unmeasurable here) | ping minima over 10 s | none |
| 6.2.11 | decoys | one record per decoy at its rate, per viewer | — | behaviour call and diff: 236 ns native, 288 interpreted per viewer per state tick (measured); 100 viewers at 20 Hz ≈ 0.5 ms/s; a fresh table per call (garbage); per-viewer sections defeat broadcast (finding 3) | previous decoys | none |
| 6.2.12 | canaries | min(16, maxBytes) B per add | — | 13 ns native per inbound string; 80 ns and an allocation per inbound buffer (measured; finding 9) | 32 B per value per player (finding 9) | none |

Only one pair catches the same thing at the same cost: traps and reachability. Every other pair prices a
different route or a different property of the same call. Caller identity and caller source can't be reduced to
one: an attacker who lowers identity still fails the source check, and the reverse.

---

## Part D. Hot-path cost: draft 2 against draft 1

**Server inbound, per message after decode** (`inbound_hotpath.out`):

| Path | Native | Interpreted |
|---|---|---|
| draft 1 (lookup, direction and lane, rate bucket) | 23.0 ns | 86 ns |
| draft 2 (adds permutation, trap flag, reachability lookup, slack bucket) | 39.3 ns | 125 ns |

That is +16 ns per message native. At 100 players × 60 messages/s it is ≈0.1 ms/s. Further per-message costs:
`refers` lookup 23 ns native per referencing field; canary 13 ns per string field, 80 ns per buffer field (finding
9). The per-frame tag and replay window are unchanged from draft 1.

**Server outbound:**
- **Rows.** Encode once per record per tick (75 ns native), then 27.6 ns per selected row per viewer, the cheaper
  of the two options measured.
- **Scheduler.** FIFOs, per draft 1's measurement.
- **Decoys.** 236 ns per viewer per state tick when enabled.
- **Broadcast.** Draft 2 loses the `FireAllClients` path for unreliable broadcasts (finding 3), which costs more
  than all of the above combined once the engine's per-call cost is counted. That is unmeasured (§11).

**Client outbound:**
- per fire: the probe's random draw (24–32 ns), and the limit bucket and FIFO (cheap);
- per frame: the tag, now on ack-only frames too, at 20–60 per second when idle (finding 4).

**Client inbound:** copy-on-write record per applied row, 182 ns and 320 B interpreted (Part A, R18).

**Bytes per frame:** busy players, see R5 in Part A. Idle upstream got worse: 154–461 B/s and 20–60 calls/s,
against 129 B/s and 10 calls/s (finding 4).

---

## Part E. Counters and sequences after draft 2

| Counter | Width | Scope | Jobs | Note |
|---|---|---|---|---|
| state tick T | 16 (unreliable), delta (reliable) | server clock | time, `Lync.tick()` | derivable on the client from epoch: finding 14; per-player delta: finding 3 |
| downstream unreliable seq | 12 | per player | ack target, row ordering | per player defeats broadcast (finding 3); stored comparison bug (finding 1) |
| ack `received` | 16 | per player | notify, `impossibleAck`, rewind | fine |
| upstream reliable count | implicit | per connection | tag | fine |
| upstream unreliable seq | 12 | per connection | replay window, tag, `inputs` index | fine; one counter, three jobs |
| request slot + outcome | 4 + 2 | per direction | requests | fine (R16) |
| slot generation | 2 | per slot | unreliable row disambiguation | redundant on the reliable lane (finding 11) |
| `BEACON` stamp | 16 (ms mod 2^16) | per player | clock rate | wraps at 65 s, beacons are at most 10 s apart: fine |
| `REPORT` counts | EG-0 | per player | client facts | probes-only reports (finding 8) |

Draft 1 had eight schemes. Draft 2 has six that do distinct jobs, plus the generation and two report counters.
None duplicates another except as noted. The two open problems are both about the downstream unreliable seq:
its scope (finding 3) and its stored comparison (finding 1).

---

## What is good

- **Section skipping is gone.** The per-list counts, the backwards tail and frame-whole refusal remove a class of
  decoder desynchronisation at a lower bit cost than draft 1.
- **The `:newest()` decision is made from a measured table** and states its cost (13 Hz updates for a
  100-player shooter at default budget). My row probe confirms its CPU half.
- **Middleware is deleted rather than restricted**, and `limit` absorbed `cooldown`. One rejection hook remains.
- **The upstream unreliable sequence is one counter with three jobs**, which is the right shape.
- **Every integrity option now has a type, unit, range, default and cost**, which is what made findings 2 and 7
  checkable at all.
- **Draft 2's per-message inbound additions measure at +16 ns native.** The new client-side measures are cheap
  where it matters.
