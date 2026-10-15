# Review: Lync v5 design draft 1, redundancy and inefficiency

Reviewed: `.data/docs/design/v5.md` as of 2026-10-15, after the lead's edits: `maxRate` removed, no
audience-by-field shortcut, `collection` name settled, §5.1 rewritten with `Lync.flush()` and
`Lync.scheduler("manual")`, §6.4 rewritten with exact triggers and weights, and the new principle 5
("precise, never simplified"). None of those edits is reported here as a finding.

Scope: narrow. (1) Every place with two ways to do one thing. (2) Bits, bytes, CPU and allocations
spent without need. API beauty, typing and gaps belong to the broad review. I mention them only when
they decide a redundancy question.

Probes are in `.data/docs/probes/review-redundancy/`, with raw output in the `.out` files beside them:

| Probe | Settles |
|---|---|
| `wire_overhead.py` | header, ack, section, handshake, intern-table and ring arithmetic |
| `sched_fifo.luau` | per-tick accumulator plus 40-bucket pass, against per-class FIFOs |
| `get_snapshot.luau` | clone-on-`get` against copy-on-write records |
| `dispatch.luau` | direct call, `pcall`, pooled thread and fresh thread per handler |
| `halfsiphash_cost.luau` | tag cost per frame |

The Luau timings come from the Luau 0.740 CLI at `-O2`, interpreted and `--codegen`, on a shared
2.1 GHz Xeon with 4 cores. Each is the median of 5–7 runs. CLI timings don't transfer exactly to
Roblox. Byte figures are arithmetic from the layout in the design, and the assumptions are printed in
the script.

## Summary

| # | Finding | Severity | Cost today |
|---|---|---|---|
| 1 | Acks are keyed by a tick that several unreliable frames share | blocking | lost `:newest()` values are never repaired, or every frame is resent |
| 2 | The input stream has no downstream ack, so "since last ack" means "always 32" | major | ≈45 B against 6.5–9 B per input packet: about 2.7 KB/s against 0.5 KB/s upstream |
| 3 | `:newest()` fields are both "absolute, encoded once" and "column-coded with prediction" | major | about 2× bytes on motion fields, or per-viewer encoding |
| 4 | Per-connection intern ids defeat encode-once and `FireAllClients` | major | every frame with a string becomes per-player; the table fills in about 14 min; up to 92 MB |
| 5 | The frame header repeats the tick and the ack | major | 886 → 353 B/s up and 353 → 130 B/s down per busy player |
| 6 | Section `kind` + `length` can't do what it is there for | major | 11 bits per section, and skipping a section corrupts the shared byte tail |
| 7 | Per-build field rotation is subsumed by other measures and drags in seven surfaces | major | contradicts "same wire"; adds a seed, a debug map, a release action and CI mode |
| 8 | Inbound rejection has four hooks and two rate limiters | major | ordering undefined; `onReceive` is missing from the pipeline |
| 9 | `newest` on events is the no-repair scheme the research ranked worst | major | up to 342 ticks stale [state-sync §1.7]; duplicates collection `:newest()` |
| 10 | Per-tick accumulation and the 40-bucket pass serve only the extension's case | minor | 1.2–5.8× the scheduling CPU of per-class FIFOs |
| 11 | Priority and rate are set in two places, and `:owner()` means three things | minor | undefined semantics |
| 12 | Oversized unreliable items are handled three ways | minor | dead demotion path and a per-item sequence |
| 13 | Tooling: four artefacts where two suffice; plugin and CLI both regenerate | minor | |
| 14 | Traps are declared two ways, one of them in runtime config for a build artefact | minor | |
| 15 | `timestamped` costs 8 bits per event where 2 bits per frame carry the same information | minor | 8 bits per stamped event |
| 16 | Request ids are explicit u16 values on a lane that already counts | minor | 16 bits per request; 12 per reply |
| 17 | The handshake sends per-definition hashes and a seed on every join | minor | 411–2415 B where 6–10 B suffice |
| 18 | `get` clones on every call | minor | 166 ns and 320 B per call, interpreted |
| 19 | The notify ring is twice the ack window | minor | about 2× ring memory |
| 20 | Codec overlaps (taste) | taste | |

---

## 1. Acks are keyed by a tick that several unreliable frames share (blocking)

**Section.** §5.2 ("Upstream frames carry the newest server tick the client applied, as a u16 tick plus
a u32 bitfield"), §5.1 ("A flush includes state only when a state tick is due"; "Every frame carries a
u16 tick"; `Lync.flush()`), §4.1 (unreliable frames packed to at most 1000 B).

**Case.** The tick is the state tick, which runs at 20 Hz. Unreliable frames go out more often than
that:
- unreliable server events flush every frame (60 Hz), so three flushes share one tick;
- `Lync.flush()` adds frames inside a tick;
- a notify update over 1000 B splits into two frames with the same tick. For example, 100 fighters ×
  (51 position bits + 29 rotation bits) ≈ 1000 B absolute, before headers.

Suppose the state frame for tick T is lost and an unreliable event frame stamped T arrives. The client
acks T. The server can't tell which frame with tick T arrived, so it has two choices:
- treat ack(T) as covering every frame sent at T, so the lost `:newest()` fields are never re-dirtied.
  That is v4's failure mode, at most 342 ticks stale `[state-sync §1.7]`;
- treat it as covering none of them, so everything is resent.

**Cost.** Notify repair, the mechanism §5.2 was chosen for, is undefined whenever a tick has more than
one unreliable frame.

**Smallest fix.** Give downstream unreliable frames their own per-player sequence, 12 bits, and make
the ack refer to that sequence, not to the tick. Keep the u16 tick on unreliable frames for time
alignment. This is the counter split shown in finding 5.

## 2. The input stream has no downstream ack (major)

**Section.** §5.2, row "client inputs": "every input since the last ack, delta-coded, capped at 32".
§4.1 frame layout: the ack exists "upstream frames only".

**Case.** Nothing in a server→client frame acknowledges the client's unreliable frames, so the client
never learns which inputs arrived. "Since the last ack" therefore collapses to "the last 32 inputs,
every packet".

**Cost.** state-sync §4.1 measured 5.1 B at R=1 and about +1.3 B for each extra copy, up to R=6. Linear
extrapolation to R=32 gives ≈45 B per packet, against 6.5–9 B for since-ack. At 60 Hz that is
≈2.7 KB/s against ≈0.5 KB/s upstream per player. That is an estimate; the extrapolation is mine. The
redundancy beyond the server's jitter-buffer depth of 2–5 ticks buys nothing `[state-sync §4.1]`.

**Smallest fix.** The upstream unreliable 12-bit sequence already exists for the replay window (§6.2).
Use it as the input index too, and add its newest-received value to downstream unreliable frames
(12 bits) whenever the player has an input stream. One counter then does three jobs: replay window,
input index and input ack.

## 3. `:newest()` fields can't be both encoded once and predicted (major)

**Section.** §4.3 ("motion fields use guarded linear prediction, which halves position bits", and "the
measured 0.45 ms per tick for 100 players"). §5.2 (`:newest()` fields are "absolute quantized values
encoded once per tick; per-viewer dirty bits").

**Case.** `position = t.vector3(-2048, 2048, 1/32):newest()` is a motion field, so §4.3 predicts it,
but §5.2 sends it absolute and encodes it once. Each claim excludes the other:
- **Prediction needs a baseline the receiver holds.** On the lossy lane that is a per-viewer acked
  baseline `[compression §4.3]`, so every viewer gets a different residual.
- **Column coding with a per-frame k runs over each viewer's selected subset of records.** That is
  per-viewer encoding too.
- **The 0.45 ms figure assumes per-viewer encoding.** It is computed as "100 recipients × 300 values ×
  15 ns" `[compression §3.2]`, not as encoding once.

**Cost.** With absolute rows (encode once, copy chunks), shooter at 20 Hz costs 381 B per frame
(`abs_row_bits`), against 186 B for `col_bits_pred` on acked baselines `[compression §2.1]`. In the
state-sync simulation, notify cost 166 B per tick against 88 B for acked-baseline deltas. Either the
bytes double, or the CPU is per viewer and "encode once" is false.

**Smallest fix.** State the choice. The cheapest consistent one is:
- `:newest()` fields are absolute rows, with a per-frame column FOR (min and width over the
  partition's records) and no temporal prediction;
- prediction applies to reliable-lane fields and to inputs only;
- the "halves position bits" claim moves to the `acked` extension.

The alternative is to predict against the newest tick acked by every member of the partition: one
encode per partition, with frames sized by the slowest viewer. That needs measuring first.

## 4. Per-connection intern ids defeat encode-once and `FireAllClients` (major)

**Section.** §4.4 ("a per-connection, append-only intern table … at most 4096 entries"), §5.4
("Records that share an audience are encoded once for all its members"), §4.1 (`FireAllClients` "when
every recipient's frame is identical").

**Case.** `fighters.name = t.string(20)`. The same name gets id 17 on one connection and id 203 on
another, so any section containing a string is different for every recipient:
- the §5.4 shared encoding fails for every record with a string field;
- a chat broadcast to `Lync.all` can never use `FireAllClients`.

There is also no way to keep one-off strings out of the table. Chat lines are interned like item names,
so a 50-player server producing 5 unique broadcast lines per second fills every table in 13.7 minutes
(`wire_overhead.out`). After that, every new name is sent inline for the rest of the server's life. On
the upstream side, a cap of 4096 × `t.string(200)` × 100 connections allows up to ≈92 MB of server
memory.

**Cost.** Encode-once is lost for string-bearing records, and so is `FireAllClients` for any frame
with a string. The table degrades within minutes, and the memory bound is large.

**Smallest fix.**
- Intern per audience, not per connection. One table per `Lync.group()`, with `Lync.all` as one
  group. A joining member receives the group's table in its catch-up.
- Intern on second sight: a 1-bit "intern this" flag on each literal, which the sender sets the second
  time it sees a string. One-off chat lines never enter the table, and no receiver mirroring is needed.
- Bound memory by total bytes, not by entry count.
- Decide `FireAllClients` eligibility structurally, from a per-player "has per-player content" flag,
  rather than by comparing frames.

## 5. The frame header repeats the tick and the ack (major)

**Section.** §4.1 frame layout; §5.2 acks and heartbeat; §6.2 tag and 12-bit sequence.

**Case.** The header spends bits on information it already has:

| Field | Redundant with |
|---|---|
| upstream `tick:u16` | the ack: the client's "tick" is the newest server tick it applied `[state-sync §6.2]` |
| `ack:u16 ackBits:u32` on both lanes, every upstream frame | one ack per client frame is enough; it changes only when a new downstream unreliable frame arrives (20 Hz) |
| downstream reliable `tick:u16` | the reliable lane is ordered: the tick is the same as the previous frame's or one more, two times in three at 60/20 Hz |
| 32-bit ack bitfield | at the busy profile each downstream frame is acked 116 times. Sent only when new, a 16-bit field still gives 17 repeats; P(never acked) = 8e-23 at 5% loss |

**Cost.** From `wire_overhead.out`, including section framing (finding 6):

| Profile | Direction | Design (B/s) | Proposed (B/s) |
|---|---|---|---|
| busy | up | 886 | 353 (−60%) |
| busy | down | 353 | 130 (−63%) |
| idle | up | 115 | 71 |
| idle | down | 135 | 100 |

An upstream input packet carries a 12.9 B header for a 6.5–9 B payload. The proposal makes the header
4.3 B, or 7.8 B when it carries a new ack.

**Smallest fix.**
- Delete the upstream tick.
- Carry the ack once per client frame, on whichever lane sends first, behind a presence bit, and only
  when it is new.
- The ack is a 12-bit downstream unreliable sequence (finding 1) plus a 16-bit bitfield.
- Code the downstream reliable tick as a delta: `0` same, `10` +1, `11` + u16.
- Tie the idle heartbeat to "unacked downstream unreliable frames exist", not to a fixed 10 Hz. "Idle"
  is undefined today.

Every ack-derived check survives: rewind reads the newest ack, which is unchanged when omitted. The
consistency checks are unchanged.

## 6. Section `kind` + `length` can't do what it is there for (major)

**Section.** §4.1 (`section := kind:u3 length:prefixVarint body`, "a bad or unknown section is skipped,
not fatal to the frame"); §4.3 (a single "byte-aligned tail" per frame holds every literal string and
buffer); §6.1 ("A refused section is skipped by its length prefix; the rest of the frame still
delivers").

**Case.** Section A, a run of `chat` events, is refused, and section B, more `chat`, follows. Skipping
A by its bit length leaves A's string bytes unread at the head of the shared tail, so B decodes A's
text. A per-section length doesn't make skipping work unless every section also carries a tail length.

The length doesn't serve the `rate` check either. Rate is per definition, and an events section mixes
definitions, so a rate refusal must drop one message, not one section. On rate there are also two
contradictory statements: §3.4 enforces it "before decode", while §6.1 runs decode (step 4) before rate
(step 5).

What remains is "unknown kind", which the handshake's version check already excludes, and "malformed",
which for a frame that passed the tag means a bug or an attacker. Dropping the rest of that frame costs
an honest client nothing.

Downstream, the client never skips: the server is trusted. The kind is also implied, because §4.1
fixes the section order: adds and updates → events, requests and replies → removes.

**Cost.** 11 bits per section (3 + an 8-bit varint, 19 bits above 127 B). At the busy profile that is
192 B/s per player downstream, 1.2% of the default `stateBudget`, and it buys nothing.

**Smallest fix.**
- Replace per-section `kind` and `length` with a frame-level presence bitmask, one bit per section
  kind, in fixed order.
- Drop lengths.
- A malformed section drops the rest of its frame, counted as `Malformed`.
- Write the byte tail backwards from the end of the buffer, so no tail offset is needed either.
- Settle the rate order: decode the definition id, check `rate`, and decode the body only if the check
  passes.

## 7. Per-build field rotation is subsumed by other measures and drags in seven surfaces (major)

**Section.** §6.2, row "Per-build field-order rotation (generated path, nonzero seed)"; §4.5 (build
seed in `HELLO`); §8.1 (`debugmap.json`, "decode rotated traffic"); §8.2 (`[build] seed`, `[rotate]
fields`); §8.3 ("Prepare release", CI `seed = "release"`); §0 ("same wire" on both paths).

**Case.** Upstream, the tag already rejects any frame not produced by Lync's encoder, which is what
static byte tooling produces. Downstream, an ESP doesn't decode bytes at all. It reads `Net.fighters:get`
or hooks `changed` through `getconnections`, and the decoder sits in the client shard as constants
anyway. The research's own verdict on reshuffling with the tag on is "small" `[client-security §3.4]`.

Rotation also breaks the design's own invariants:
- it applies to the generated path only, so the runtime path's wire differs from it, against §0 "same
  wire";
- the §4.5 fallback from stale generated code to the runtime path can change field order in the middle
  of a session.

It is also reachable two ways: `seed = 0` disables it, and so does `[rotate] fields = false`.

**Cost.** Zero bytes, but seven surfaces: `[build] seed`, `[rotate]`, `seed = "release"`, the plugin's
"Prepare release", the seed in `HELLO`, the rotation half of `debugmap.json`, and golden-test seeding.
All of them exist for a measure with no remaining attacker.

**Smallest fix.** Delete per-build rotation and everything listed above. Keep the per-server id
permutation: it is runtime-only, costs no tooling, and is the only measure that breaks copy-paste byte
scripts across servers.

## 8. Inbound rejection has four hooks and two rate limiters (major)

**Section.** §3.5 `validate`; §7.2 middleware `onReceive(player, data) -> data?` ("nil drops the
message"); §6.3 constraints with policy `drop | clamp | signal`; §6.3 `:claim(verifier)`; §3.4 `rate`;
§6.3 `cooldown`.

**Case.** "Reject `buy` when the player is dead" can be written four ways: in `validate`, in
`onReceive` returning nil, as a constraint, or as a claim verifier. Their order relative to each other
is undefined, and `onReceive` doesn't appear in the §6.1 pipeline at all. A drop in `onReceive` also
produces no `Suspicion` and no `rejected` reply, so a request dropped there times out after 10 s — the
v4 bug that §3.5 says is fixed.

`cooldown = c` is a token bucket with rate 1/c and burst 1. `rate` is a token bucket with burst 2 ×
rate. Those are two rate limiters with two failure-policy surfaces: `rate` always drops and signals
`RateExceeded`, while `cooldown` takes `drop`, `clamp` or `signal`.

**Smallest fix.**
- Keep constraints, which are declarative and compiled, and one function hook, `validate`.
- Make `:claim()` a bare marker whose rule is "a definition with claim fields must have `validate`",
  rather than a second verifier slot.
- Restrict `onReceive` to transforming data: it may not return nil. Run it after `validate`, and list it
  in §6.1.
- Fold `cooldown` into `rate` as `rate = { perSecond, burst }`, with burst a declared number rather
  than the fixed preset 2 × rate (principle 5).

## 9. `newest` on events is the no-repair scheme the research ranked worst (major)

**Section.** §3.4 table: `newest` on event ("only the latest value per recipient is kept and sent");
§3.6 / §5.2 collection `:newest()`.

**Case.** `roundTimer = Lync.event({ from = "server", lane = "unreliable", newest = true })`. If the
last update before the timer stops is lost, clients show the wrong value until the next change. That is
the "changed only, unreliable, no repair" row of state-sync §1.7: max 342 ticks stale, the worst scheme
measured. On the reliable lane, `newest` presumably means coalescing within a flush, but that is
undefined (principle 5). Meanwhile a collection field with `:newest()` gets notify repair. These are
two mechanisms for "latest value wins", and one of them is known broken.

**Cost.** Unbounded staleness for every game that uses the simpler-looking option.

**Smallest fix.** Delete `newest` from events. Make `key` optional on `collection`: an omitted key means
one record with a 0-bit key, which is the singleton. Values that must converge are then state, and
state gets repair.

## 10. Per-tick accumulation and the 40-bucket pass serve only the extension's case (minor)

**Section.** §5.3 ("accumulates `priority × boosts` per tick … a 40-bucket log2 pass"; `maxPendingAge`).

**Case.** In the core there is no distance term, so a pending record's rate of priority growth is
constant: definition `priority` × owner boost × first-send boost. Its accumulator is exactly
`weight × ticksPending`. Two consequences follow:
- **The bucket pass is unnecessary in the core.** Records become pending in time order, so one FIFO
  per (viewer, weight class) is already sorted by age. Selection is a merge of the class heads by
  `weight × age`. That is exact, where the buckets approximate within a power of two, and records
  that aren't sent need no per-tick work.
- **`maxPendingAge` becomes a head check.** Age is the key the FIFOs already hold.

Only the `interest` extension makes weights vary per tick, and only it needs the bucket pass.

**Cost.** Measured in `sched_fifo.luau`, the same work in both modes (marking, selection, the same
records sent), with chunk copying excluded. Times are ms per state tick for all viewers, median and
two reruns:

| Viewers × records, dirty, sends | Bucket, native | FIFO, native | Bucket, interpreted | FIFO, interpreted |
|---|---|---|---|---|
| 100 × 300, 30%, 50 | 0.83–1.22 | 0.39–0.55 | 2.11 | 1.14 |
| 200 × 300, 30%, 50 | 1.4–1.8 | 0.87–2.25 (noisy) | 4.39 | 3.83 |
| 100 × 1000, 30%, 50 | 4.2–5.0 | 0.74–1.04 | 8.16 | 1.61 |
| 200 × 1000, 10%, 83 | 2.7–3.6 | 1.6–2.7 | 7.36 | 4.48 |

At 20 Hz with 100 × 1000 records, that is ≈85–100 ms/s against ≈15–20 ms/s of one core.

**Smallest fix.** In the core, use per-class FIFOs with a `pendingSince` per (viewer, record). Move the
accumulator and the bucket pass into `interest`, which replaces the selector through a seam. With many
classes (many collections × boosts), use a small heap over the class heads.

## 11. Priority and rate are set in two places, and `:owner()` means three things (minor)

**Section.** §3.4 (`priority`, `rateHz` on collection); §3.6 (`:priority(weight)`, `:rate(hz)`,
`:owner()` on fields); §5.3; §7.3 `interest` visibility class `owner`.

**Case.**
- **Field `:priority`.** The scheduler selects records, not fields, and the design doesn't say what a
  record's weight is when `position:priority(4)` and `name:priority(1)` are both dirty: maximum, sum, or
  the definition's value.
- **`rateHz` against `:rate(hz)`.** `rateHz` on the collection and `:rate(hz)` on every field express
  the same cap twice.
- **`rate` means two things.** It is an inbound token bucket on events and an outbound send cap on
  collection fields.
- **`:owner()` means three things.** It is a priority boost in the core (§3.6), a boost multiplier
  (§5.3 "boosts", undefined), and a visibility class in `interest`. Nowhere does the schema say who owns
  a record.

**Smallest fix.**
- Priority lives only on the collection. Delete field `:priority`.
- The send cap lives only on fields, under a name other than `rate`. Delete `rateHz`, since
  `stateRate` is the default.
- Declare ownership once, for example `owner = "key"` when the key is a `UserId`. Define the owner boost
  as a number with a default, per principle 5.

## 12. Oversized unreliable items are handled three ways (minor)

**Section.** §4.1 ("A single item that can't fit is demoted to the reliable lane with its sequence
intact. Items whose worst-case size can exceed the limit are refused at build time"); §8.2 `[check]
unreliableSize = "error"`.

**Case.** If the build refuses every item whose worst case exceeds the limit, no single item can fail to
fit an empty frame. Runtime demotion, and the per-item sequence it carries, are then dead code, unless
the TOML knob is set to `"warn"`. The knob makes a "refused" rule optional.

**Cost.** A per-item sequence that appears nowhere else in the layout (a fifth counter; see the
summary under finding 16), plus a cross-lane newest-wins rule.

**Smallest fix.** Keep the build-time refusal as a rule. Delete the `unreliableSize` knob, runtime
demotion and the per-item sequence.

## 13. Tooling: four artefacts where two suffice; plugin and CLI both regenerate (minor)

**Section.** §8.1, §8.3, §8.4.

**Case.**
- **Two JSON files for CI.** `manifest.json` (worst-case sizes, reachability, for CI) and `report.json`
  (for CI gates) are both machine-readable inputs to CI, with overlapping facts.
- **`debugmap.json` is redundant.** It exists to decode rotated traffic (finding 7) and to let the
  inspector decode frames, but the plugin embeds the planner (§2), so it holds the IR.
- **Two generators.** In a Rojo project, `lync watch` writes shards to disk while the plugin
  "regenerates on schema edit" into the DataModel. Rojo then syncs both, and two writers race on the
  same files.

**Smallest fix.**
- Ship one `manifest.json` (machine) and `report.md` rendered from it.
- Delete `report.json` and `debugmap.json`; the inspector decodes through the embedded planner.
- The plugin regenerates only when the configuration lives in its `StringValue`, that is, in a
  Studio-only project. With a filesystem `lync.toml`, it only runs diagnostics and the inspector.

## 14. Traps are declared two ways, one in runtime config for a build artefact (minor)

**Section.** §6.2 ("server-only `:trap()`, plus generated client→server ids hidden from the typed API");
§6.5 `Lync.integrity({ traps = 2 })`.

**Case.** Generated trap ids must exist in what the client can browse, the shard or its runtime tables,
but their count is set in a server-only runtime call. Either the server sends them to the client at run
time (undefined), or a runtime setting can't affect the already-built client shard. Both mechanisms
target the same attacker: one who browses the schema and calls the API. "2" is also a preset count
rather than a definition, which principle 5 forbids.

**Smallest fix.** Keep declared `:trap()` only and delete `traps = N`. If generated traps stay, define
where their names come from and make them a build option in `lync.toml`.

## 15. `timestamped` costs 8 bits per event where 2 bits per frame carry the same information (minor)

**Section.** §3.4 `timestamped`; §5.6 ("adds a 1-byte sub-tick offset").

**Case.** Events are flushed once per frame at `PostSimulation`. Everything fired within one frame
leaves together, and Roblox runs input callbacks inside the frame's step, so the offsets of events in
the same frame differ only by script execution time. That last point is an inference; Studio can check
it. The useful information is "which frame within the tick": 2 bits per frame at 60/20 Hz, 1 bit at
60/30, and 0 at 60/60.

**Cost.** 8 bits per stamped event. Stamped 60 Hz inputs cost 60 B/s for what 15 B/s carries.

**Smallest fix.** Put a frame-in-tick index in every frame header, at 0–2 bits. `timestamped` then
becomes an API flag only (handlers receive the stamp) with no wire cost.

## 16. Request ids are explicit u16 values on a lane that already counts (minor)

**Section.** §5.5 ("u16 request ids in a ring"); §6.2 (implicit reliable-frame counter).

**Case.** Requests travel on the reliable, ordered lane, so both ends can count them: the nth request
received is request n. Only replies, which handlers answer out of order, need an id. Because in-flight
requests are capped at 16 per player, the id can be an offset into the in-flight window: 4 bits.

**Cost.** 16 bits per request and 12 per reply.

**Smallest fix.** Use implicit request ids and a 4-bit reply offset. `UnknownReply` stays exact, since
an offset outside the window is impossible for an honest client.

**Counters overall.** The draft runs these sequence and counter schemes:
- downstream tick, on both lanes;
- upstream tick;
- ack and bitfield;
- the implicit reliable counter;
- the upstream unreliable 12-bit sequence;
- request ids;
- the per-item demotion sequence;
- the sub-tick offset.

With findings 1, 2, 5, 12, 15 and 16, four remain:
1. the downstream state tick (explicit on unreliable, delta on reliable);
2. a downstream unreliable sequence, which is the ack target;
3. the upstream unreliable sequence, used for the replay window, the input index and the input ack;
4. the implicit reliable counters, used for the tag and request ids.

## 17. The handshake sends per-definition hashes and a seed on every join (minor)

**Section.** §4.5.

**Case.** `HELLO` carries a hash for every definition, plus the build seed and a layout format, even
when the schema hash matches, which is the normal case. Per-definition hashes matter only for
diagnosing a mismatch. The seed goes away with finding 7. The format can fold into the protocol
version.

The client also holds every reliable send for one round trip waiting for `WELCOME`. The server could
fire `WELCOME` at `PlayerAdded`, unsolicited. The client would then find it queued when it connects and
could send at once, while the server holds data until `HELLO`. This relies on reliable remote events
queuing for a late listener, which is unverified and needs a Studio check.

**Cost.** `HELLO` grows from 6–10 B to 411 B (100 definitions, 32-bit hashes) or 2415 B (300
definitions, 64-bit hashes), plus one round trip of held client sends per join. The hash widths are
undefined (principle 5).

**Smallest fix.** `HELLO` = version + schema hash. Per-definition hashes are sent only after a mismatch.

## 18. `get` clones on every call (minor)

**Section.** §3.5 (`get` returns "a frozen snapshot, never the live table"); `changed(id, fighter,
previous)`.

**Case.** Taken literally, `get` clones and freezes on every call. Client code that reads 50 fighters
per `RenderStepped` performs 3000 clones per second.

**Cost.** Measured in `get_snapshot.luau`:

| Operation | Interpreted | Native |
|---|---|---|
| `table.freeze(table.clone(record))`, 6 fields | 166 ns, 320 B | 118 ns, 320 B |
| copy-on-write `get` | 7 ns, 0 B | 2.5 ns, 0 B |
| copy-on-write change: build the next frozen record | 182 ns, 320 B | 143 ns, 320 B |

**Smallest fix.** Use copy-on-write records. Each change builds the next frozen record once. `get`
returns it, and `changed` passes the previous one as `previous` without a further allocation. Whenever
reads outnumber changes, this is cheaper, and it removes the separate allocation for `previous`.

## 19. The notify ring is twice the ack window (minor)

**Section.** §5.2; state-sync §4.2 (a 64-entry ring per viewer against a u16 + 32-bit ack, which covers
33 frames).

**Case.** A frame older than newest − 32 can't be acked by any future upstream frame, so ring entries 34
to 64 are never consulted. With the 16-bit bitfield of finding 5, 17 entries suffice.

**Cost.** For 200 records per frame, the ring holds 25 KB per viewer as u16 in a buffer and 200 KB as a
Luau array, against 12.9 KB and 103 KB at 33 entries (`wire_overhead.out`).

**Smallest fix.** Size the ring to bitfield + 1 and store it in a buffer.

## 20. Codec overlaps (taste)

1. **`t.vector3()` against `t.vector3(min, max, step)`.** The arity changes the wire (f32 against
   predicted fixed point) and the coder (f32 columns can't be predicted). That breaks §3.3's "nothing
   optional changes the meaning". Give the f32 form its own name.
2. **`t.map(key, value, maxCount)` (§3.3) against `t.map(base, decode, encode)` (§7.1).** One name
   names two different things. Rename the transform.
3. **`t.number(min, max, 1)` against `t.int(min, max)`.** These are the same bits with different
   fraction handling (round against refuse). Reject an integer step in `t.number` at declaration, and
   point to `t.int`.
4. **`t.int()` against `t.int(min, max)`.** These code identically in columns and differ only in
   validation and single-row width. Keep both, but say so in the table.
5. **`t.cframe(position, rotation)` against a record `{ position, look }`.** These are the same columns.
   Keep `t.cframe` for its value type. Document that the decoder builds the CFrame once
   `[compression §4.5]`.

---

## Checked and kept

These overlaps were tested and the design is right to keep them:
- **Requests against events plus a reply.** Requests own the id, timeout, result union and
  `rejected`. Rebuilding them from events would push id bookkeeping onto every user.
- **`t.union` against `t.optional`; `t.buffer` against `t.string`; `t.angle` against `t.number`.** The
  types differ, and `t.angle`'s wrapped residual has no `t.number` equivalent.
- **`audience` against `interest`.** Audience is the encode-once partition and interest refines it per
  viewer. The design should state that interest intersects audience and never widens it. One sentence
  in §5.4.
- **One ack serving notify, rewind and the consistency checks.** This is good reuse.
- **HalfSipHash tag cost.** Measured in `halfsiphash_cost.luau`:

  | Frame size | Interpreted | Native |
  |---|---|---|
  | 64 B | 3.2 µs | 0.48 µs |
  | 1024 B | 37 µs | 5.5 µs |

  The per-byte cost is about 35 ns interpreted, roughly 1.5–2.7× client-security §3.1's unmeasured
  estimate of 13–23 ns. A client sending 64 B frames at 60 Hz still pays only ≈0.2 ms/s. Keep it, and
  correct the brief's figure.
- **A pooled thread per handler.** Measured in `dispatch.luau`, interpreted:

  | Call | Cost |
  |---|---|
  | direct | 14 ns |
  | `pcall` | 35–46 ns |
  | pooled resume | 88–131 ns |
  | fresh coroutine | 319–451 ns |

  At 6000 messages/s the pooled thread costs ≈0.5 ms/s. Keep the pool. Never spawn a fresh thread per
  message. Running `validate` under `pcall` and the handler in the pooled thread is two dispatches per
  message; that is acceptable.

## Where the mechanisms I reviewed simplify instead of defining (principle 5)

- §5.3 **"boosts"**: which boosts exist and their values.
- §3.6 **`:owner()`**: "higher priority" by how much, and who the owner is.
- §5.2 **"idle client"** for the 10 Hz heartbeat.
- §4.4 **interning**: which strings are interned, and the syntax for "templates".
- §3.4 **`newest`** on the reliable lane.
- §5.2 **jitter buffer**: "2–5 ticks", but by what rule.
- §3.4 **`burst = 2 × rate`**: a fixed preset, not an option.
- **Where settings are set**: `stateRate`, `stateBudget`, `maxPendingAge` and `maxPendingFrames`. None
  has a stated configuration surface.
- §4.5 **hash widths**: the schema hash and the per-definition hashes.
- §4.1 **`kind:u3`**: which kinds exist.
- §8.2 **`seed = "release"`**: a label standing in for a definition.
- §4.1, §5.4 **catch-up keyframe**: its format.

## What is good

- The §3.3 rule that rejects a flags codec (record bools are the bitfield) is the right instinct, and
  most of the codec table already follows it.
- One planner shared by runtime, CLI and plugin removes a whole class of drift.
- Folding direction and lane into the schema hash gives certainty at zero bytes.
- Reusing `Lync.group()` for both `fire` targets and collection audiences, and the new §5.4 refusal of
  a field-partition shortcut, are exactly the "one way" principle applied.
- The implicit reliable counter for the tag is a zero-byte design. Findings 1, 2 and 16 extend the same
  idea to the other counters.
