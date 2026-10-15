# State synchronization, scheduling and consistency for Lync v5

Researcher brief, 2026-10-15. Scope: **what is sent, when, to whom, and how it stays consistent** across Lync's
two lanes (reliable ordered `RemoteEvent`, unreliable `UnreliableRemoteEvent` ≤ 1000 B). Byte-level encoding
and compression belong to another brief and are only touched where they change a scheduling decision.
Not repeated here: `landscape.md` (wire overheads, zstd, limits), `v4.md` §4 (sets), `v5-attempt.md` §3
(collections, settle), `anticheat-design.md` (relevancy design, acks for rewind).

Labels: **verified** (I ran it, or read the primary source code), **documented** (vendor docs), **reported**
(third party, talk summaries, forum), **unverified** (memory or inference). Probes are in
`.data/docs/probes/state-sync/` and ran on Luau 0.740 CLI (Linux, Xeon 2.1 GHz, shared and noisy: treat ±40 %
as noise), `-O2` interpreted and `-O2 --codegen` native; Python sims run with `python3 -I`. Native code runs on
Roblox servers only; clients are interpreted (`landscape.md` §3.2). Primary sources downloaded for this brief
(not committed): ioquake3 `main`, OpenTNL `ghostConnection.cpp`/`netObject.cpp`, Unity `com.unity.netcode` 7.1.0,
Mirror `master`, FishNet `main`, Source SDK 2013, GGPO, Roblox `creator-docs` (commit of 2026-10-14).

| Probe | What it answers |
|---|---|
| `interest_cost.luau` (+ `.out`) | relevancy cost: brute force vs grid vs cell subscriptions, 50–200 players × 1k–10k entities |
| `sched_cost.luau` (+ `.out`) | per-viewer accumulate + select + copy under a byte budget; sort vs bucket vs round-robin |
| `encode_once_cost.luau` (+ `.out`) | encode once and copy vs per-viewer delta encoding, ns per record |
| `state_sync_sim.py` (+ `.out`) | nine state schemes over the two lanes under Bernoulli and bursty loss: bytes vs staleness |
| `input_redundancy_sim.py` (+ `.out`) | redundancy depth for input streams vs jitter-buffer depth and burst loss |
| `fairness_sim.py` (+ `.out`) | starvation under budget: strict priority vs accumulator vs round-robin |

---

## 0. Bottom line

1. Every successful large-scale model since Tribes (1998) has the same core: **the server keeps, per client, which
   pieces of state that client lacks, and each tick fills a byte budget with the most important of them, sending
   the newest value**. Retransmission of old values is avoided. Tribes/Torque, Halo Reach, Unreal (generic and
   Iris), Unity Netcode for Entities and Photon Fusion all have this shape; they differ in how "lacks" is tracked
   (acked baselines vs dirty masks plus loss notification).
2. Lync's lanes split the problem cleanly. The **reliable lane** already gives ordered delivery, so structural
   state (add, remove, audience changes) and exact fields replicate as **deltas against last sent, without acks**,
   which is what v4 and the attempt did. That stays.
3. The **unreliable lane** is where v4 and the attempt were weakest:
   - v4 sends newest fields with sequence numbers and no repair;
   - the attempt added "settle", a reliable resend after 0.5 s idle.
   The sim (§1.7) shows that without repair a lost final update stays wrong for the whole idle period (300+ ticks),
   and settle still allows 47–83 ticks under bursty loss. The fix with no per-client encoding is the **Tribes notify
   model**: per-client dirty bits for newest fields; absolute quantized values encoded once per tick for all viewers;
   a u16 frame ack plus u32 ack bitfield upstream; on a lost frame, re-dirty only fields not superseded since. It
   matched acked-baseline delta compression in staleness at about 1.9× its bytes, with no snapshot history.
4. **Per-client delta-vs-acked-baseline (Quake 3, Netcode for Entities)** is the byte-optimal model. In Luau it costs
   per-viewer encoding (measured 48 ns vs 25 ns per record native, 237 vs 43 interpreted) plus a snapshot ring per
   client. Keep it out of the core; it can be an opt-in codec for one hot collection later.
5. **Scheduling** should copy Iris and Netcode for Entities: priority accumulates while a record has unsent changes
   and resets when it is *sent*, not acked; selection is an O(n) bucket pass, not a comparator sort (measured 3.5–7×
   cheaper); over budget means **defer** (coalescing bounds the backlog by the record count); precision is never
   coarsened at runtime, rate is reduced by distance band instead.
6. **Interest management cost is dominated by maintaining per-viewer membership, not by the spatial query.**
   - Distance-exact membership for 200 players × 10k entities costs about 4–7 ms per pass native.
   - Cell subscriptions cost about 0.01 ms per pass, plus about 0.15 ms for cell moves, but over-include about 2.6×.
   - Recommended split: cells decide membership (with hysteresis); distance decides priority and rate inside the budget.
7. **Inputs on the unreliable lane:** send every input since the last acked one, delta-coded against the previous
   input in the packet (GGPO, Gaffer, Overwatch, Netcode for Entities). This costs 6.5–9 B per packet in the sim.
   Redundancy is useless beyond the server's jitter-buffer depth: under bursty 5 % loss, a 1-tick buffer misses
   5 % whatever the redundancy, while a 5-tick buffer with acked redundancy misses 0.97 %.
8. **Cross-lane ordering:** Roblox orders reliable remotes across instances per connection, but nothing orders
   unreliable remotes, and property replication under NextGenerationReplication (required for Server Authority) is
   unordered relative to remotes. Lync should emit each reliable frame as **adds/updates → events → removes**, so
   "spawned then announced" and "announced then removed" both hold, and every frame carries a tick so unreliable state
   and reliable events can be aligned.
9. **Time:** tick numbering at the state rate (u16 in the frame header) beats wall-clock stamps. `GetServerTimeNow`
   is documented as smoothed and monotonic, with rate within 0.6 % of the local clock, but its absolute error is
   undocumented (users report "a few ms"). Interpolation delay should be `max(2 × send interval, 100 ms)` (Source)
   with Mirror-style jitter adaptation. Extrapolation should be capped at 250 ms (Source `cl_extrapolate_amount`).
10. **Budget:** Roblox publishes none (docs give ~500 client→server calls/s per remote type, nothing for
    server→client; "50 KB/s" is folklore, `landscape.md` §2.3). Recommend a per-player **state** budget of 16 KB/s
    (configurable 4–64 KB/s) at a 20 Hz state tick (10–60). Events and replies are not limited by it but are charged
    first, so state yields to them. All of this needs Roblox measurement (open questions in Implications).

---

## 1. State synchronization models (Q1)

### 1.1 Snapshot interpolation

- **Mechanism** (Gaffer, [Snapshot Interpolation](https://gafferongames.com/post/snapshot_interpolation/), verified by
  reading): the server sends the visible state of all objects every snapshot; clients buffer and render between two
  snapshots, a fixed delay in the past.
- **Bandwidth:** high without delta. 900 cubes × 225 bits ≈ 25 KB per snapshot: 11.6 Mbit/s at 60 Hz, about 2 Mbit/s
  at 10 Hz. Hermite interpolation needs velocity and adds bytes.
- **Latency:** the interpolation delay, sized to survive two consecutive losses, "3X the packet send rate": 300 ms at
  10 pps (350 ms with jitter), 150 ms at 30, 85 ms at 60.
- **CPU and memory:** encode per client, or once if identical for everyone; the client keeps 3–5 snapshots.
- **Loss and reorder:** a lost snapshot is skipped (interpolate toward a newer one); stale ones are dropped by sequence.
- **Late join:** free.
- **Fit with Lync:** full snapshots hit the 1000 B unreliable cap quickly (64 records × 8 B = 512 B), so chunking or
  delta is required. Keep the client-side interpolation *buffer* as a helper for newest fields (§6). Extrapolation
  "ignores floor collisions, spring forces, and collision response"; Gaffer raises the send rate instead.

### 1.2 Delta against the last acknowledged baseline (Quake 3, Gaffer)

- **Mechanism** (verified in ioquake3 source):
  - The server keeps `PACKET_BACKUP 32` snapshots per client (`qcommon.h:123`).
  - It deltas each new snapshot against the one the client last acked (`client->deltaMessage`).
  - It falls back to a full snapshot when the ack is older than `PACKET_BACKUP - 3` frames ("Delta request from out of
    date packet", `sv_snapshot.c:136-140`), or when the entity ring has rolled over.
  - Fields are diffed blindly via `netField_t` (name, offset, bits), with a 1 changed-bit per field
    ([Sanglard](https://fabiensanglard.net/quake3/network.php)).
  - Defaults: `snaps 20`, `sv_fps 20`, `rate 25000` bytes/s (`cl_main.c:3668-3669`, `sv_init.c:667`).
- **Rate control drops whole snapshots.** When the rate budget is exceeded, the server skips that client's snapshot
  this frame (`rateDelayed`, `sv_snapshot.c:656-683`). It also skips while fragments are still queued, "or delta
  compression will break".
- **Gaffer's version** ([Snapshot Compression](https://gafferongames.com/post/snapshot_compression/)):
  - The packet header carries `uint16 sequence, uint16 base, bool initial`.
  - The baseline advances only on a newer ack, so in steady state it is about one RTT old.
  - An unchanged cube costs 1 bit: 901 bits per packet, about 54 kbps at 60 Hz. Indexing changed cubes averages
    5.5 bits per index and is used when ≤ 90 cubes changed.
  - A stationary scene drops to about 15 kbps, mostly headers. The start point was 17.38 Mbps.
- **Bandwidth:** the best of all models: unchanged state costs nothing, and deltas are small (baseline ≈ one RTT old).
  **Latency:** one way plus interpolation delay.
- **CPU and memory per client:** encoding is per client, because baselines differ, and a history ring is kept per client
  (Q3: "8 MB for 4 players", reported by Sanglard). In Lync: per-viewer encode (§3.6: about 2× copy cost native, 5×
  interpreted) plus per-viewer rings.
- **Loss / reorder / late join:** robust (any delivered packet decodes against a baseline the client provably has);
  drop older than newest; the first packet is relative to an initial state, i.e. a full snapshot.
- **Fit with Lync:** best bytes on the unreliable lane. The cost is per-client encoding and memory, which hurts in
  Luau at 100+ players; it also forces an upstream ack stream. Netcode for Entities is the modern instance (§2.3).

### 1.3 Delta against last sent on an ordered reliable channel

- **Mechanism:** both sides apply every delta in order, so the receiver's state equals the sender's last sent state
  and no acks are needed. Used by v4 sets, the attempt's collections ("no acks"), Godot `ON_CHANGE` ("updates using
  reliable transfer mode when its value changes", [docs](https://docs.godotengine.org/en/stable/classes/class_scenereplicationconfig.html)),
  Mirror default `SyncMethod.Reliable`, and Warp's XOR delta (`landscape.md` §1.6).
- **Bandwidth:** near-optimal. The sim's `rel_delta` scheme is the cheapest at 73 B/tick, against 88 for acked-baseline,
  because the delta is always against the immediately previous value.
- **Latency:** fine without loss. Under loss, **head-of-line blocking** stalls every later reliable message until
  retransmission. Roblox orders all `RemoteEvent`s of a connection together ("including across different RemoteEvent
  instances", creator-docs `scripting/events/remote.md`), so one lost packet delays every Lync reliable section and
  every other remote of the game. Assuming RTO = 3 ticks, the sim puts p99 staleness at 17 ticks (850 ms) under 5 %
  bursty loss and 41 under 15 %, against 3 and 5 for unreliable schemes. Roblox's real RTO is unknown.
- **CPU and memory:** encode once per partition for all its viewers (v4); server keeps last-sent state per partition.
  **Late join:** catch-up keyframe (v4 has it).
- **Fit:** the right default for structural changes, exact fields and anything whose intermediate values matter.
  It is wrong for continuously moving values, because the stall hits exactly the data that is stale fastest.

### 1.4 Eventual consistency with priority accumulators (Tribes, Halo Reach, Gaffer)

- **Tribes/Torque mechanism** (OpenTNL, verified in source):
  - Each ghost has a per-connection `updateMask` of dirty field groups. Each packet, objects in scope are ranked by
    `getUpdatePriority(scope, mask, updateSkipCount)` and the packet is filled in order; sent objects' masks clear and
    `updateSkipCount` resets (`ghostConnection.cpp:250-402`). The default priority is `updateSkips * 0.1`
    (`netObject.cpp:166-168`), a starvation counter that games override with distance and view terms.
  - On a **dropped packet**, `packetDropped` ORs back only the flags "we haven't updated since this (dropped) packet"
    (`ghostConnection.cpp:100-130`). Old values are never retransmitted; superseded data is not resent.
  - Ghost ids are `GhostIdBitSize` 10 bits, 1024 ghosts by default
    ([doxygen](https://opentnl.sourceforge.net/doxytree/classTNL_1_1GhostConnection.html)).
- **Halo Reach** (Aldridge, GDC 2011; reported via [Edgegap](https://edgegap.com/blog/game-backend-deep-dive-halo-reach-netcode-host-migration)
  and [Wolfire](https://www.wolfire.com/blog/2011/03/GDC-Session-Summary-Halo-networking)):
  - Tribes-based, three protocols: *state* (eventually consistent, intermediate values skipped), *events* (unreliable,
    context), *control* (about 20 bits per player of sub-sampled input, relayed). Priority per object per client:
    distance, screen presence, threat, interaction history. "unreliability enables aggressive prioritization".
  - 250 kbps for 16 players against a 384 kbps goal; over 2000 synchronized entities. A one-line grenade-priority fix
    freed about 20 % of bandwidth, dropping ragdoll sync 10–12 %: priority tuning, not encoding, was where the bytes were.
- **Gaffer's version** ([State Synchronization](https://gafferongames.com/post/state_synchronization/)):
  - Each frame every object's priority is added to its accumulator; objects are sorted by it; "If you encounter a state
    update that doesn't fit, skip over it and try the next one"; sent objects reset to zero, the rest keep growing.
  - Priorities: player 1,000,000, interacting cubes 100, resting 1. 64 updates per packet, 256 kbit/s, jitter buffer
    4–5 frames at 60 Hz, quantization applied on *both* sides so extrapolation agrees.
- **Bandwidth:** bounded by the budget by construction; updates are absolute values. **Latency:** important objects
  lead every tick, unimportant ones drift. **CPU:** a priority pass, O(relevant) per viewer (§3.5). **Memory:**
  per-client dirty masks plus per-packet "what I sent" lists. **Loss:** robust, newer values supersede. **Reorder:**
  needs a per-object sequence or packet tick so an older packet cannot overwrite a newer value.
- **Late join and new viewer:** everything in scope is dirty, so priority spreads the catch-up over several ticks
  under the budget.
- **Fit with Lync:** the best fit for newest fields on the unreliable lane.
  - Absolute values are the same for every viewer, so encode once per tick.
  - Selection and repair are per viewer, but they are bit operations, not encoding.
  - It needs an upstream ack bitfield, which the anti-cheat design wants anyway (`anticheat-design.md` §4.1).

### 1.5 Deterministic lockstep and rollback (GGPO)

- **Lockstep** (Gaffer, [Deterministic Lockstep](https://gafferongames.com/post/deterministic_lockstep/)): only inputs
  travel; each UDP packet carries all unacked inputs at 1 bit per unchanged input (worst case 120 inputs in 90 B). The
  receiver stalls when an input is missing. It is smooth at "2 seconds of latency and 25% packet loss", against TCP
  hitches at 1 %, and needs determinism "Exact down to the bit-level".
- **Rollback (GGPO):** predicts remote inputs and re-simulates on correction ([README](https://github.com/pond3r/ggpo)).
  `SendPendingOutput` sends every input since `_last_acked_input`, writing only changed bits (`udp_proto.cpp:110-160`,
  verified).
- **Costs:** bandwidth independent of object count; latency is input delay or rollback; CPU is re-simulation; late
  join needs full state plus inputs.
- **Roblox relevance:** none as a Lync model. Physics is engine-owned and not deterministic across machines, clients are
  interpreted while servers may be native, and Server Authority already does engine prediction and resimulation
  (`landscape.md` §2.4). What transfers is the **input-redundancy protocol** (§4.1), for game input that is not an
  engine `InputAction`.

### 1.6 Comparison

| Model | Bytes | Latency under loss | Server CPU per viewer | Server memory per viewer | Late join | Lync lane |
|---|---|---|---|---|---|---|
| Snapshot interpolation (full) | highest | interp delay only | encode once if shared | ~0 | free | unreliable, only tiny worlds |
| Delta vs acked baseline | lowest | interp delay only | **per-viewer encode** | snapshot ring | full snapshot | unreliable, opt-in |
| Delta vs last sent, reliable | low | **HOL stalls** | encode once per partition | ~0 | keyframe | reliable, default for exact state |
| Notify / eventual consistency | medium (absolute values) | interp delay; repair ≈ 1 RTT | select + bits; encode once | dirty masks + in-flight lists | spread over budget | unreliable, newest fields |
| Lockstep / rollback | inputs only | stalls / rollbacks | re-sim | input history | full state | none (inputs only) |

### 1.7 Simulation: the schemes on Lync's lanes

Setup (`state_sync_sim.py`):
- 20 Hz, 64 records.
- Records alternate moving and idle (about 29 % moving); a moving record changes every tick.
- Absolute record = 8 B; delta = 3/5/8 B by baseline age; id = 1 B.
- One-way 1 tick, RTT 2 ticks.
- The reliable lane retransmits after an **assumed** RTO of 3 ticks and blocks later packets.
- Staleness = ticks since the sender's value first moved past the value shown (minimum 1 for a moving record).
- 8 seeds × 1200 ticks.

| Scheme | B/tick | 5 % Bernoulli: mean / p99 / max | 5 % bursty (mean burst 3): mean / p99 / max | 15 % bursty: mean / p99 / max |
|---|---|---|---|---|
| full state, unreliable | 512 | 0.30 / 2 / 3 | 0.34 / 3 / 16 | 0.42 / 5 / 19 |
| changed only, unreliable, no repair (v4-like) | 165 | 2.28 / 69 / 342 | 1.90 / 59 / 307 | 5.36 / 114 / 342 |
| changed, each update sent twice | 173 | 0.44 / 2 / 232 | 1.47 / 43 / 307 | 3.59 / 91 / 307 |
| changed + settle 10 ticks (attempt-like) | 174 | 0.34 / 2 / 14 | 0.34 / 2 / 47 | 0.58 / 10 / 83 |
| delta vs acked baseline (Q3) | 88 | 0.30 / 2 / 4 | 0.34 / 3 / 15 | 0.44 / 5 / 19 |
| reliable baseline 1 Hz + unreliable since-baseline (Mirror) | 214 | 0.31 / 2 / 7 | 0.48 / 6 / 41 | 0.86 / 17 / 53 |
| **notify: dirty + ack re-dirty (Tribes)** | **166** | 0.30 / 2 / 6 | 0.35 / 3 / 16 | 0.45 / 6 / 20 |
| delta vs last sent, reliable (v4 sets) | 73 | 0.39 / 4 / 10 | 0.89 / 17 / 71 | 3.24 / 41 / 72 |
| delta chain, unreliable, keyframe 1 s (Warp on unreliable) | 95 | 1.63 / 21 / 40 | 1.09 / 19 / 53 | 3.08 / 40 / 114 |

What it shows (verified by running; the byte sizes are assumptions):
- **Lossy "newest" without repair is the worst scheme for idle records.** The last update before a record stops is
  lost forever: max 342 ticks, which is the whole idle period.
  - Sending each update twice does not fix bursts.
  - Settle bounds the error at the settle delay plus reliable HOL.
- **Notify matches acked-baseline staleness at the same loss**, at about 1.9× the bytes (166 vs 88 B/tick), with no
  per-viewer encoding and no snapshot history.
- **Reliable delta is the cheapest** but degrades fastest under bursts: p99 17–41 ticks. The real penalty depends on
  Roblox's RTO, which is unmeasured.
- **Mirror's reliable-baseline scheme** costs more bytes than notify (214 vs 166 B/tick), because "changed since
  baseline" grows toward the full set between baselines. It also inherits HOL on the baseline.
- **Unreliable delta chains** are fragile, which is why Warp keeps them on the reliable lane (`landscape.md` §1.6).

---

## 2. How modern engines do it (Q2)

### 2.1 Unreal: generic replication, ReplicationGraph, Iris

- **Generic** (documented, [Actor Priority](https://dev.epicgames.com/documentation/en-us/unreal-engine/actor-priority-in-unreal-engine)):
  `NetPriority` 1.0 for actors, 3.0 for pawns and player controllers ("The only thing that matters with priorities is
  their ratio"). `GetNetPriority` scales by owner, view and distance (×0.2 from 500 to 2000 units, ×2.0 if looked at
  within 8000, ×0.4 beyond 3162) and time since last replicated; saturated connections are load-balanced by priority.
- **Per-property conditions** ([docs](https://dev.epicgames.com/documentation/en-us/unreal-engine/replicate-actor-properties-in-unreal-engine)):
  `COND_InitialOnly`, `COND_OwnerOnly`, `COND_SkipOwner`, `COND_SimulatedOnly`, `COND_AutonomousOnly`, `COND_Custom`
  (toggled per actor at runtime), `COND_Dynamic`, `COND_Never` and others; "every replicated property only replicates on
  the condition that it has changed".
- **ReplicationGraph** (documented, cited in `anticheat-design.md` §1.1): built for Fortnite (100 players, about 50,000
  replicated actors). Spatial-grid nodes hold per-cell actor lists; a connection gathers the lists for its area plus
  always-relevant lists. This is the cell-subscription idea measured in §7.2.
- **Iris** (documented, experimental; [overview](https://dev.epicgames.com/documentation/en-us/unreal-engine/iris-replication-system-in-unreal-engine),
  [components](https://dev.epicgames.com/documentation/unreal-engine/components-of-iris-in-unreal-engine),
  [prioritization](https://dev.epicgames.com/documentation/en-us/unreal-engine/iris-prioritization-in-unreal-engine)):
  - **Push-based dirty tracking:** "Iris does not expect the replication system to poll for changes". Replication
    states carry a dirty bitfield per member. Without push model it falls back to polling at `NetUpdateFrequency`
    (migration doc).
  - **Quantized state copies:** "a full copy of all replicated state data in a quantized form". The pre-send update is
    the only step that reads gameplay data (poll if legacy, copy and quantize dirty state, reset dirtiness, update
    filtering and prioritization); then each connection's stream schedules dirty objects by priority and dependencies.
  - **Priority accumulation:** "accumulates across network ticks until an object is replicated and its priority is
    reset"; priority < 1.0 means not considered this frame. Sphere defaults `InnerRadius=1000, OuterRadius=5000,
    InnerPriority=1.0, OuterPriority=0.2, OutsidePriority=0.1` (squared falloff); `SphereWithOwnerBoost` adds
    `OwnerPriorityBoost`; `NetObjectCountLimiter` `MaxObjectCount=2` with an owned-objects fast lane.
  - **Delta compression is opt-in per class and capped:** `bEnableDeltaCompression`, `MaxDeltaCompressedObjectCount`;
    `SetDeltaCompressionStatus` "does not guarantee that the object will use delta compression"
    ([API](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/IrisCore/UReplicationSystem/SetDeltaCompressionStatus)).
    Epic treats per-connection baselines as a scarce resource, not the default.
  - **Filtering:** separate from prioritization; filter groups capped by `MaxNetObjectGroupCount`.

### 2.2 Fortnite

ReplicationGraph and Iris are both "built on Epic's experience with Fortnite Battle Royale" (documented). I found no
primary source saying whether Fortnite runs Iris today (searched Epic docs and forums). The lessons are the ones above:
spatial lists instead of per-actor-per-connection checks, push-model dirtiness, and opt-in capped delta baselines.

### 2.3 Unity Netcode for Entities (verified in `com.unity.netcode` 7.1.0 source and 1.5 docs)

- **Snapshots:** "one snapshot to each connected client once per tick" (`DefaultTickRate = 60`). When the network tick
  rate is below the simulation rate, connections are **round-robined across ticks** to spread send CPU
  ([ghost snapshots](https://docs.unity3d.com/Packages/com.unity.netcode@1.5/manual/ghost-snapshots.html)). Snapshots
  are clamped to MTU (`DefaultSnapshotPacketSize`, min 100 B): "it's common and expected for a snapshot to only contain
  a subset of all ghosts".
- **Importance:** per *chunk* of entities, multiplied by `ticksSinceLastSent` ("not `ticksSinceLastAcked`"); it
  "increases by the Importance value every tick, until sent (NOT confirmed delivered)" (`GhostSendSystem.cs`).
  Modifiers: `FirstSendImportanceMultiplier`, `MinSendImportance`, `IrrelevantImportanceDownScale`, per-connection
  `BatchScaleImportanceFunction` with tiled distance (`GhostDistanceImportance`). Since 1.4 per-prefab `MaxSendRate` is
  preferred (rate 10 = "on every tenth snapshot"). Over budget, "all remaining ghost entities are simply not sent on
  this tick" ([optimizations](https://docs.unity3d.com/Packages/com.unity.netcode@1.5/manual/optimizations.html)).
- **CPU guards:** `MaxSendChunks`, `MaxSendEntities`, `MaxIterateChunks` ("very useful when dealing with thousands of
  static ghosts"); `PercentReservedForDespawnMessages` default 33 %, "we recommend around 75% for large scale games".
- **Baselines and history:** deltas predicted from "the last 3 baselines", or `UseSingleBaseline` (client
  deserialization "reduced by a good ~50%"). History 32 by default, for "~500ms at a 60hz NetworkTickRate" (builds may
  use 16 or 6; clamped 4–32). 7.x recommends per ghost type `ceil(0.35 s × tickRate / sendInterval) + 5`: "a baseline
  slot for every in-flight (un-acked) snapshot, plus the acked baseline … plus two more for partial sends". Static
  ghosts that do not change are not sent "at all".
- **Change detection** is by serialize-and-compare ("If the job did not change the `GhostField`, it discards the
  serialized result"): polling that costs CPU even for unchanged data.
- **Client timing:** `InterpolationTimeNetTicks = 2`, `MaxExtrapolationTimeSimTicks = 20`, `MaxPredictAheadTimeMS = 500`,
  `TargetCommandSlack = 2`. Each input packet carries `TargetCommandSlack + NumAdditionalCommandsToSend` = 4 commands "as
  a packet loss recovery mechanism" (`NetworkTimeSystem.cs:217-225`, `ClientServerTickRate.cs:628`). Prediction time
  scale `1 + 0.1 × commandAge` is Overwatch-style dilation.

### 2.4 Photon Fusion

- Product page (documented, [photonengine.com/fusion](https://www.photonengine.com/fusion)): "Full Consistency
  (default): Uses additional bandwidth per object to ensure each object is internally consistent"; "Eventual
  Consistency … Uses less bandwidth per object … the state seen on each object might be from two different ticks";
  "6x smaller than MLAPI or Mirror" at a 20 Hz packet rate (vendor claim).
- The Fusion 2 manual and API were behind a bot wall (WebFetch and curl), so its change tracking and AOI cells are
  **unverified** here. A 2026 case study reports a custom AOI holding 264 players in one zone on Fusion 2.1 (reported,
  [blog](https://blog.photonengine.com/?p=5033)).
- **Takeaway:** Fusion makes the consistency trade explicit. Lync faces it for records with both reliable and newest
  fields (§5.3 item 4).

### 2.5 Valve Source and CS2

- **Source SDK 2013** (verified): interpolation = `max(cl_interp 0.1, cl_interp_ratio 2 / cl_updaterate)`
  (`cdll_bounded_cvars.cpp`); `cl_extrapolate_amount 0.25` s (`interpolatedvar.cpp:29`); lag compensation capped by
  `sv_maxunlag 1.0` s (`player_lagcompensation.cpp:34`). Acked-frame delta snapshots are inherited from Quake (the Valve
  wiki returned 403, so details are unverified).
- **CS2 "sub-tick"** (Valve, 2023-03-22, reported via
  [Wccftech](https://wccftech.com/counter-strike-2-sub-tick-reponsiveness-announced-limited-test-today/amp/)): "Sub-tick
  updates are the heart of Counter-Strike 2"; the server knows "the exact instant" of movement, shots and throws,
  independent of tick rate. Mechanically, commands carry intra-tick timestamps (§6.4).

### 2.6 Overwatch (GDC 2017) and Rocket League (GDC 2018)

- **Overwatch** (reported via the [GDC Vault](https://gdcvault.com/play/1024001/-Overwatch-Gameplay-Architecture-and)
  listing and an [Edgegap summary](https://edgegap.com/blog/game-backend-deep-dive-overwatch-2016-netcode-architecture-rollback);
  recording not watched): fixed 16 ms command frames; the client runs about RTT/2 + 1 frame ahead; every input since
  the last acked one goes in each packet; on input starvation the client "dilates" (about 15.2 ms per 16 ms step) to
  grow the server's input buffer, then dilates back; rewind uses about 0.5 s of per-entity history.
- **Rocket League** (only secondary summaries reachable,
  [Game Developer](https://gamedeveloper.com/design/video-the-rocket-science-behind-i-rocket-league-s-i-physics);
  **unverified, from memory of the talk**): 120 Hz Bullet physics, state at about 60 Hz, clients predict all cars
  (others extrapolated with their last input), and the server steers each client's input rate to keep a small buffer.
- Transferable idea, shared with Netcode for Entities: an input buffer sized by measured jitter, steered by feedback.

### 2.7 Mirror and FishNet (verified in source)

- **Mirror dirty bits:** "Each SyncVar in a `NetworkBehaviour` script is assigned a bit in the dirty mask" (64-bit
  `syncVarDirtyBits`); `syncInterval` default 0; `syncMode` Observers or Owner
  ([docs](https://mirror-networking.gitbook.io/docs/manual/guides/synchronization)).
- **Mirror `SyncMethod.Unreliable`** (`NetworkServer.cs:56-64, 2140-2200`): a **reliable full baseline every
  `unreliableBaselineRate = 1` Hz**; unreliable deltas tagged with a `byte baselineTick`; the receiver drops deltas for
  any baseline but the newest and drops older timestamps. Optional `unreliableRedundancy`: "quake sends unreliable
  messages twice … this double bandwidth … best to turn this off unless the game is extremely fast paced". Simulated in
  §1.7.
- **Mirror snapshot interpolation** (`SnapshotInterpolationSettings.cs`): `bufferTimeMultiplier = 2`,
  `bufferLimit = 32`, catch-up +2 % beyond 1 snapshot ahead, slow-down −4 %, drift EMA 1 s, `dynamicAdjustment = true`
  with tolerance 1 and delivery-time EMA 2 s.
- **Mirror interest:** `SpatialHashingInterestManagement`, `visRange = 30`, cell = `visRange / 2`, 9-neighbour cells,
  `rebuildInterval = 1` s.
- **FishNet:** prediction resends replicates and reconciles `RedundancyCount = stateInterpolation + 1` (default 3) times
  after a change, then stops (`PredictionManager.cs:358`, `NetworkBehaviour.Prediction.cs:566-586`). Observer
  conditions: Distance, Grid, Scene, Match, OwnerOnly, HostOnly. `DistanceCondition`: `_maximumDistance = 100`,
  **hysteresis** `_hideDistancePercent = 0.1` ("must be 150f units away before this object is hidden" at 0.5).

### 2.8 Godot MultiplayerSynchronizer (documented)

`REPLICATION_MODE_ALWAYS` is "constantly sending updates using unreliable transfer mode" every `replication_interval`;
`REPLICATION_MODE_ON_CHANGE` uses "reliable transfer mode when its value changes" every `delta_interval`; `spawn`
properties go only in the spawn packet. Visibility: `public_visibility`, `set_visibility_for`,
`add_visibility_filter(Callable)`, `visibility_update_mode` (idle, physics, manual)
([MultiplayerSynchronizer](https://docs.godotengine.org/en/stable/classes/class_multiplayersynchronizer.html),
[SceneReplicationConfig](https://docs.godotengine.org/en/stable/classes/class_scenereplicationconfig.html)). This is the
simplest complete vocabulary: **spawn-only / on-change reliable / always unreliable** per property, plus per-peer
visibility.

### 2.9 Techniques worth copying

| Technique | Where | What Lync should do |
|---|---|---|
| **Dirty tracking, push model** | Iris, Mirror `SetDirtyBit`, Netcode for Entities write-access | Lync's API is already push: every write goes through `update`/`set`. Mark per-field dirty bits at write time; never poll or compare on flush. Unity's serialize-and-compare is what to avoid |
| **Change masks per record** | Q3 `netField_t` bits, Mirror 64-bit masks, Iris member bitfields | per-record field mask (v4 has fieldset list or 64-bit mask forms). Keep; group rarely-changing fields |
| **Per-client dirty state for unreliable fields** | TNL `updateMask` + `packetDropped` | per-viewer dirty bits for newest fields only; re-dirty on loss unless superseded |
| **Per-property conditions** | Unreal `COND_*`, Godot spawn/sync/watch, Mirror `syncMode` | schema modifiers: `:initial()` (join/enter only), `:owner()`, `:skipOwner()`, plus a visibility class (`anticheat-design.md` §1.4) |
| **Priority that accumulates until sent** | Gaffer, Iris, Netcode for Entities (`ticksSinceLastSent`) | accumulator per (viewer, record) with pending changes, reset on send |
| **Rate caps per type** | Netcode for Entities `MaxSendRate`, Mirror `syncInterval`, Godot intervals | `:rate(hz)` on newest fields and definitions; rounded down to a divisor of the state tick |
| **Budget per packet, skip what does not fit** | Gaffer, Netcode for Entities, Q3 `rate` | per-viewer byte budget per lane per tick; skip and keep accumulating |
| **Reserved share for structural messages** | NfE `PercentReservedForDespawnMessages` | removals and audience changes charged first; never starved by updates |
| **Round-robin viewers across ticks** | NfE when network rate < simulation rate | when the state tick < frame rate, spread viewers across frames (flush 1/k of players per frame) to flatten server CPU |
| **Opt-in, capped per-connection baselines** | Iris `MaxDeltaCompressedObjectCount` | if acked-baseline deltas ever ship, opt-in per collection with a cap |
| **Static objects cost nothing** | NfE `OptimizationMode.Static` | records with no dirty fields are not visited (dirty lists, not scans) |
| **Spatial lists, not pair tests** | ReplicationGraph, Mirror spatial hashing | cell subscriptions (§7) |
| **Hysteresis** | FishNet 10 %, Riot "stay relevant a short time" | leave radius = enter × 1.1–1.25, or a time hold |

---

## 3. Bandwidth scheduling (Q3)

### 3.1 What Roblox gives and says

- **Documented** (creator-docs `RemoteEvent.yaml`, `UnreliableRemoteEvent.yaml`, `scripting/events/remote.md`, fetched
  2026-10-15): client→server "approximately 500 requests per second, per client … **shared among all remote events of
  the same type**"; excess reliable calls are delayed, excess unreliable dropped; unreliable payloads over 1000 B are
  dropped, and unreliable methods "encode and compress certain object types, such as buffers"; unreliable messages may
  drop when "the network is congested and the message waits too long to send". No server→client limit is documented.
- **An internal allocator exists but is not exposed:** the MicroProfiler scope "Allocate Bandwidth and Run Senders"
  (`tag-table.md`), and `NetworkPeer:SetOutgoingKBPSLimit(limit)`, PluginSecurity, "clamped to the range 10–10,000"
  kbit/s (`NetworkPeer.yaml`). Neither is a per-player script budget.
- **Folklore and measurements:** "50 KB/s per player" (old Dev Hub text, removed, units disputed:
  [thread](https://devforum.roblox.com/t/does-the-50kbps-data-limit-only-apply-to-remote-events-or-also-server-side-object-creation/580567)).
  The attempt measured about 240 KB/s of random buffer payload to one Studio client (`v5-attempt.md` §9), so it is not
  a hard cap. A staff reply says replication steps "target 30hz" and queue when they cannot fit
  ([thread](https://devforum.roblox.com/t/calling-remotes-right-before-network-replication/149120)); community claims of
  20 and 60 Hz conflict.
- **Implication:** Lync shares the pipe with engine replication (characters, physics, streaming) and cannot see the
  engine's queue. Its budget must be conservative, configurable, and ideally react to observed congestion (§3.7).

### 3.2 Choosing a default budget

Reasoning (my judgement; the numbers are anchors, not measurements):
- The unreliable frame cap is 1000 B. At a 20 Hz state tick one full unreliable frame per tick is 20 KB/s; at 60 Hz it
  is 60 KB/s.
- Engine traffic for 30–50 nearby characters (physics replication) must fit in the same connection. Its size on
  Roblox is unmeasured (open question).
- ioquake3's default `rate` is 25,000 B/s. Halo Reach ran 16 players in 250 kbit/s ≈ 31 KB/s from the host for all
  clients (reported). Gaffer's examples target 256 kbit/s = 32 KB/s.
- Mobile players are a large share on Roblox. Their downstream is rarely the limit, but their CPU is: client decode
  is interpreted (`landscape.md` §3.2).

Recommended defaults:

| Knob | Default | Range |
|---|---|---|
| `stateRate` (Hz) | 20 | 10–60, a divisor of 60 |
| `stateBudget` (bytes/s per player, both lanes, state only) | 16,000 | 4,000–64,000 |
| burst allowance (multiple of per-tick budget) for catch-up and audience changes | 4× for at most 1 s | — |

Consequences:
- 16 KB/s at 20 Hz is 800 B per tick, which fits under the 1000 B unreliable cap after a frame header.
- Events, replies and requests are **not** limited by the budget, since they carry user intent and must be delivered,
  but their bytes are **charged first**. State gets whatever remains, down to a floor of 25 % of budget so state
  never starves completely.

### 3.3 Priority accumulators and relevancy scoring

Recommended per-viewer score for a record with pending changes:

`acc += weight(def) × distanceFactor(viewer, record) × ownerBoost` every state tick while pending; reset to 0 when
sent.

- `weight(def)`: schema-declared, default 1. Unreal's 1/3/3 shows that ratios are all that matter.
- `distanceFactor`: banded, as in the Iris sphere prioritizer (inner 1.0, outer 0.2, outside 0.1, squared falloff)
  or Unreal's ×0.2/×0.4 bands.
- `ownerBoost`: for the viewer's own records, ×4 (`SphereWithOwnerBoost` idea).
- **First-send boost:** ×4 for records new to this viewer (Netcode for Entities `FirstSendImportanceMultiplier`), so
  catch-up is front-loaded by importance, not arrival order.
- No view-cone term in the core: it needs a camera direction upstream. That belongs in an extension with the anti-cheat
  `:aim()` stream.

### 3.4 Starvation and fairness

- `fairness_sim.py` setup: one viewer; 1 own record weighted 50, 30 near weighted 4, 200 far weighted 0.25; 10 B per
  update; dirty probability 0.5 per tick, coalesced.
- At 50 % of demand:
  - **strict priority starves far records** for the whole run (p99 2934 ticks);
  - **accumulators** keep far records at mean 1.1 / p99 3 ticks while own and near stay at 0;
  - round-robin spreads delay to everyone (own 0.9 / near 0.9 ticks).
- At 20 % of demand, accumulators give far p99 16 ticks, round-robin gives own p99 9.
- Accumulators give proportional share. With coalescing ("pending" is a flag, not a queue) the backlog is bounded by the
  record count, so there is no unbounded queue to starve behind.
- The worst-case wait of a pending record is about `weight_max / weight_min` × (records ahead / per-tick capacity).
  Lync should expose a **max-age floor** (default 2 s): a pending record older than that goes first. The sim never
  triggered it at these loads; it is insurance.

### 3.5 Measured scheduling cost (`sched_cost.luau`)

Per tick, for all viewers: accumulate over the viewer's relevant records, select within the budget, `buffer.copy`
12-byte chunks from a shared encode-once buffer.

| Viewers × relevant | Budget/tick | rr (native / interp) | bucket (native / interp) | sort (native / interp) |
|---|---|---|---|---|
| 100 × 300, 30 % dirty | 600 B | 0.88 / 1.68 ms | 1.76 / 2.32 ms | 9.1 / 7.4 ms |
| 200 × 300, 30 % dirty | 600 B | 2.44 / 3.80 ms | 3.60 / 8.10 ms | 12.9 / 16.0 ms |
| 100 × 1000, 30 % dirty | 600 B | 3.19 / 5.95 ms | 5.25 / 12.0 ms | 35.5 / 51.2 ms |
| 200 × 1000, 10 % dirty | 1000 B | 3.55 / 9.50 ms | 4.40 / 11.0 ms | 19.4 / 25.8 ms |

- A comparator `table.sort` per viewer is 3.5–7× the cost of a 40-bucket pass over `floor(log2(acc))`.
- The bucket pass costs about 20–60 ns per (viewer, relevant record) natively.
- At a 20 Hz state tick, 100 × 300 costs about 35 ms/s (3.5 % of a core); 200 × 1000 about 90 ms/s.
- Optimisations to apply in the core:
  - iterate only records with pending changes: keep per-viewer pending lists, not full relevant scans;
  - schedule at the state rate, not the frame rate;
  - optionally round-robin viewers across frames (Netcode for Entities).

### 3.6 Encode once vs per viewer (`encode_once_cost.luau`)

| ns per 8-byte record | Native | Interpreted |
|---|---|---|
| quantize + write once | 12.5 | 109 |
| `buffer.copy` of a shared 8 B chunk | 24.9 | 43.5 |
| per-viewer delta vs own baseline (zigzag + varint) | 47.7 | 237 |

- For tiny records a `buffer.copy` call costs more than the encode itself. Encode-once pays when chunks are larger, or
  when contiguous records are copied in one call.
- Lync should lay out each tick's encoded records so a viewer's selection is often contiguous: sort records by
  partition and then by cell.
- Per-viewer delta is about 2× copy natively. It is affordable CPU-wise for one hot collection. The real costs are the
  per-viewer history memory and complexity, which is why it stays out of the core.

### 3.7 When the budget is exceeded: defer, drop or coarsen

| Action | Use for | Evidence |
|---|---|---|
| **Defer** (accumulator keeps growing, coalesced) | all state | Gaffer, Iris, Netcode for Entities, TNL; §3.4 sim |
| **Drop** | unreliable events past their usefulness (deadline), cosmetic events (Halo: "Low-bandwidth players may miss many special effects") | Halo Reach (reported) |
| **Skip the whole frame** | never for Lync | Q3 `rateDelayed` drops entire snapshots; fine for one delta stream, harmful when events and state share a frame |
| **Coarsen rate** (distance bands → lower Hz) | newest fields | Netcode for Entities `MaxSendRate`, Unreal distance factors |
| **Coarsen precision** | not in core | needs both sides to know the active quantization per update (a tag bit per field) and complicates delta paths; Gaffer instead *raised* precision for state sync (4096/m, 15-bit quats) because quantization drives extrapolation errors |
| **Demote oversize unreliable to reliable** | single newest values or events whose encoded size exceeds the unreliable remainder | attempt idea; §4.5 |

Congestion response (extension, needs measurement):
- Roblox exposes no send-queue depth, but Lync can observe its own signals: ack RTT and unreliable loss from the ack
  bitfield.
- An AIMD rule (multiplicative decrease ×0.7 when smoothed RTT rises above 1.5× its 10 s minimum or loss exceeds 5 %;
  additive increase +1 KB/s per second otherwise) is the TCP-friendly pattern.
- It is **unverified** whether Roblox congestion shows up in those signals before the engine starts dropping unreliable
  traffic ("waits too long to send").

### 3.8 Send rate

- **Every frame** (60 Hz) for events, replies and reliable structural changes: they are latency-bound and already
  batched per frame. v4 and every competitor flush per frame; Zap warns against firing above 60 Hz
  (`landscape.md` §2.3).
- **Fixed state tick** (default 20 Hz) for newest fields and priority scheduling.
  - Q3 used 20; Netcode for Entities 60; Fusion's benchmark 20; Mirror defaults to the tick rate.
  - The state tick sets interpolation delay, `max(2 / rate, 100 ms)`: 100 ms at 20 Hz; above 20 Hz the floor rules (§6.3).
- **Adaptive** per definition through `:rate(hz)` and distance bands. Rate is rounded down to a divisor of the state
  tick (Netcode for Entities: "45Hz at a 30Hz tick rate yields 30Hz").

### 3.9 Coalescing

Already a v4 strength (update+update merges, add+remove cancels, remove+add becomes removal + keyframe; `v4.md` §4).
In the scheduler it must extend **across ticks while pending**: a record pending for 5 ticks sends one update with its
newest values, and a reliable field changed 5 times sends its final value. Fields whose history matters should be
events, not state.

### 3.10 Exposing it with low developer effort (schema-declared)

Sketch in Luau. Names are illustrative; the point is where the knobs live.

```lua
Fighters = Lync.replicate(Lync.struct({
    name   = Lync.str(1, 20):initial(),                       -- sent on add / gaining sight only
    hp     = Lync.int(0, 100),                                -- reliable, exact, delta vs last sent
    ammo   = Lync.int(0, 255):owner(),                        -- reliable, only to the owning player
    pos    = Lync.vec3(Lync.quant(-2048, 2048, 0.05)):newest(), -- unreliable, notify-repaired
    yaw    = Lync.angle(2):newest(),
}))
    :keyBy("team")
    :priority(2)                       -- weight relative to other definitions (default 1)
    :rate(20)                          -- cap for newest fields, Hz (rounded to a divisor of stateRate)
    :interest({ at = "pos", radius = 256 })   -- extension: cell subscriptions + distance priority
Lync.configure({ stateRate = 20, stateBudget = 16000 })   -- per namespace; per-player override API
```

- Defaults with **no annotations**:
  - priority 1 and rate = `stateRate`;
  - no interest policy (audience by key, as in v4);
  - every field reliable unless `:newest()`.
- The developer adds knobs only when the profiler (§8.6) shows a definition over budget.

---

## 4. Reliability on the unreliable lane (Q4)

### 4.1 Redundancy for input streams

- **Practice:**
  - Q3 sends every usercmd since the packet `cl_packetdup` (default 1) before the previous one, capped at
    `MAX_PACKET_USERCMDS 32` (`cl_input.c:786-795`).
  - GGPO and Gaffer's lockstep send *all unacked inputs*.
  - Netcode for Entities sends 4 commands per packet; FishNet resends 3 times after a change; Overwatch sends since
    the last ack (reported).
- **Sim** (`input_redundancy_sim.py`; 4 B inputs changing 30 % of ticks; one-way 1 tick):

| Loss | Server buffer J | R=1 | R=2 | R=3 | R=4 | R=6 | since-ack |
|---|---|---|---|---|---|---|---|
| 5 % Bernoulli | 1 tick | 5.10 % | 5.10 % | 5.10 % | 5.10 % | 5.10 % | 4.96 % |
| 5 % Bernoulli | 3 ticks | 5.10 % | 0.24 % | 0.016 % | 0.016 % | 0.016 % | 0.013 % |
| 5 % bursty | 5 ticks | 5.06 % | 3.33 % | 2.21 % | 1.46 % | 0.93 % | 0.97 % |
| 15 % bursty | 5 ticks | 15.1 % | 9.92 % | 6.54 % | 4.30 % | 2.81 % | 3.04 % |
| bytes/packet | — | 5.1 | 6.4 | 7.8 | 9.1 | 11.7 | 6.5–9.0 |

- Findings:
  - **Redundancy only helps up to the server's playout-buffer depth.** A copy that arrives after the input's deadline
    is useless.
  - Bursty loss needs a deeper buffer, not more copies.
  - **Since-ack redundancy matches the best fixed depth at the byte cost of R≈2**, because repeats are delta-coded
    (1 bit when unchanged, as in GGPO and Gaffer) and stop once acked.
- Lync should provide `:input()` streams: client→server unreliable, since-ack redundancy capped at 32, server-side
  jitter buffer depth adapted to measured arrival jitter (Overwatch and Netcode for Entities steer the client clock;
  Lync can only steer the buffer).

### 4.2 Selective acks

- Gaffer's header is `uint16 sequence, uint16 ack, uint32 ack_bits`: "each ack is repeated across 32 packets", and a
  "dropped ack" is "extremely rare" ([Reliable Ordered Messages](https://gafferongames.com/post/reliable_ordered_messages/)).
- For Lync, every upstream frame (or a ≥ 10 Hz heartbeat when the client is idle) carries `ack: u16` (newest downstream
  unreliable frame tick received) and `bits: u32` (the 32 before it): 6 B per upstream frame.
- The server keeps per viewer a ring of 64 entries `{tick, records/fields carried}` for notify (§1.4): about 64 ×
  (selected records) small integers per viewer.

### 4.3 FEC and XOR parity

Standard designs are RTP ULPFEC ([RFC 5109](https://www.rfc-editor.org/rfc/rfc5109)) and FlexFEC
([RFC 8627](https://www.rfc-editor.org/rfc/rfc8627)) (unverified, from memory). XOR of k packets rebuilds any **one**
lost packet of the group at 1/k overhead, but only once the parity arrives (k ticks later, about as late as the next
update) and not for bursts. For state superseded every tick it buys little over notify repair; for inputs, since-ack
redundancy is cheaper (§4.1). Not recommended, except perhaps for large one-shot unreliable payloads.

### 4.4 Reliable-ordered messages over UDP

Gaffer's scheme keeps messages in packets until a carrying packet is acked, resends if "not sent in the last 0.1
seconds", and bounds the window by the receive buffer. Roblox already provides reliable ordered delivery, so Lync
should **not** build a second reliable channel on the unreliable lane. The one case for it, reliable-but-unordered
delivery to dodge HOL, is not justified until Roblox's HOL penalty is measured (open question).

### 4.5 When to demote unreliable traffic to reliable

- **At schema time**, compute the worst-case encoded size of each unreliable definition and newest field group
  (`landscape.md` §4, "Payload-size proofs"):
  - anything that can exceed about 900 B (1000 minus header and margin) is refused as unreliable, or marked
    `:unreliable("demote")`.
- **At run time**, a frame is split at about 1000 B. A single item that does not fit in an empty unreliable frame is
  sent on the reliable lane with a flag, keeping its sequence.
  - Receivers apply the newest-wins rule across both lanes, using tick and sequence.
- Lync counts demotions per definition in its stats: frequent demotion means the definition is mis-declared.

---

## 5. Ordering and consistency across lanes (Q5)

### 5.1 What Roblox guarantees (documented, creator-docs `scripting/events/remote.md`, `attributes.md`, `Workspace.yaml`)

- Reliable `RemoteEvent`s are ordered per connection and direction, **including across instances**; ordering applies to
  "when each handler starts, not when it finishes". `RemoteFunction`s are not ordered relative to them.
- `UnreliableRemoteEvent`s have "no ordering relationship" with anything and are discarded if no listener is connected.
- Property replication "might replicate to the client before or after" a remote fired after it. Under
  `NextGenerationReplication` (required by Server Authority), "you should not rely on the ordering of property
  replication and remote events".

### 5.2 How v4 and the attempt handled it

- **v4:** flush order is responses, requests, packets, then set changes (`Blocks.luau` classes 1–5), so a packet fired
  *after* `Fighters:add(id)` in the same frame reaches the client *before* the add. Newest set fields ride unreliable
  streams with u16 sequences and 2-bit generations (stale sections dropped); I found no ack-based repair of lost newest
  updates (inferred from `state/Newest.luau`, not run).
- **The attempt:** one bit stream per frame in call order; "settle" resends idle latest fields reliably after 0.5 s; one
  definition-id table for both lanes so items can demote.
- Neither tied unreliable state to reliable events.

### 5.3 Best practice and the recommendation

1. **Reliable frame layout: structural before events, removals after.**
   - Order: (a) adds, audience gains and reliable field updates for this frame; (b) events, requests and replies in
     call order; (c) removals and audience losses.
   - "Spawn then announce" (`add` then `Hit:fire(id)`) and "announce then remove" (`Died:fire(id)` then `remove`)
     both see the record.
   - The rarer "remove, then announce" pattern sees the record still present, which is harmless.
   - Coalescing (v4) already forbids exact program order for state; this layout restores the orders that matter.
2. **Events that reference records carry the reference as slot + generation, not a copy of the record.** The receiver
   resolves at dispatch time. A reference to a record the viewer cannot see resolves to `nil`.
   - With relevancy, such events should be scoped with `:about(ref)` (`anticheat-design.md` §1.4) so they are not sent
     at all to non-viewers.
3. **Unreliable state vs reliable events: align by tick.**
   - Every frame on both lanes carries the server state tick (u16).
   - An event whose meaning depends on a newest field ("hit at the target's position") should carry the value it
     depends on. It can also be dispatched after the client's interpolation clock passes the event's tick: an opt-in
     `:atTick()` barrier, an extension.
   - Gaffer and Halo both treat events as context, not state; Riot's worst bug class was events about state that was
     not replicated (`anticheat-design.md` §1.1).
4. **Records with both reliable and newest fields** are not atomic across lanes:
   - `hp` may update a frame before `pos`. This is Fusion's "state … might be from two different ticks".
   - Lync should document it and offer `:atomic()` on a definition, which puts every field of a changed record on the
     reliable lane in the same section (Fusion's "Full Consistency").
5. **Engine instances:**
   - With NextGenerationReplication, an `Instance` referenced in a Lync event may not have replicated yet, so it
     arrives as nil.
   - Keep v4/attempt policy: per-field nil policy. Optionally, a short client-side wait (≤ 1 s) for instances marked
     `inst():await()` (extension).

---

## 6. Time (Q6)

### 6.1 Clocks on Roblox

- `Workspace:GetServerTimeNow()` (documented, `Workspace.yaml`): "the client's best approximation of the current time
  on the server", "monotonic", moving "at the same rate as the local clock to within 0.6%"; thread-safe. A staff reply
  at release (notes 488, 2021) says it matches across server and clients "accounting for network latency"
  ([thread](https://devforum.roblox.com/t/release-notes-for-488/1379418)). Users report "a few milliseconds of variation
  across clients" ([2025-09](https://devforum.roblox.com/t/about-how-accurate-is-getservertimenow/3926695)) and that it
  reads a "frequently updated local value"
  ([thread](https://devforum.roblox.com/t/getservertimenow-is-expensive-to-call-compared-to-datetimenow/3906060)).
  Absolute error is undocumented; the 0.6 % rate bound alone allows 6 ms of slew per second.
- Under Server Authority, `time()` in bound simulation functions "is synchronized between the client and the server and
  uses fixed-step simulation time" (`projects/server-authority/index.md`), but remotes "aren't synchronized with the
  shared timeline" (`landscape.md` §2.3).
- `Player:GetNetworkPing()` returns round-trip "isolated network latency", callable on the server for any player.
- NTP-style sync is unnecessary: `GetServerTimeNow` already does it. Lync needs **tick identity**, not finer clocks.

### 6.2 Tick numbering

- Server state tick `T` increments at `stateRate`. Every downstream frame header carries `T mod 2^16`: 54 min of wrap
  at 20 Hz; compare with sequence arithmetic.
- Reliable frames sent between state ticks carry the current `T`.
- The client maps `T` to server time as `epoch + T / stateRate`, with the epoch in the handshake (v4 sends an f64
  epoch).
- It can check this against `GetServerTimeNow()` to detect frame lateness.
- Upstream frames carry the newest downstream `T` applied (the ack, §4.2). This also gives the server the client's
  perceived tick for rewind (`anticheat-design.md` §4.1).

### 6.3 Jitter buffers, interpolation delay, extrapolation

| Source | Interpolation delay | Extrapolation cap |
|---|---|---|
| Gaffer | 3 × send interval (+ jitter): 350 ms @10, 150 @30, 85 @60 | 50–250 ms, "breaks down" on collisions |
| Source | `max(cl_interp 0.1 s, 2 / updaterate)` | `cl_extrapolate_amount 0.25` s |
| Mirror | `sendInterval × bufferTimeMultiplier (2)`, dynamic from 2 s delivery-time EMA | — |
| Netcode for Entities | `InterpolationTimeNetTicks = 2` | `MaxExtrapolationTimeSimTicks = 20` (≈ 333 ms @60) |
| Gaffer state sync | jitter buffer 4–5 frames @60 (≈ 75 ms) | n/a (extrapolates by simulation) |

Recommendation for Lync's client helper (an extension; the core only provides ticks and newest values):
- Delay `= max(2 / effectiveRate, 0.1 s) + k × jitterEMA` with k = 2, re-evaluated every second.
- Catch up or slow down by ±2–4 % (Mirror's numbers) rather than jumping.
- Hermite interpolation when velocity is available, linear otherwise.
- Extrapolate at most 250 ms, then hold.
- Per-record rate differs under priority scheduling, so interpolation must use each record's own sample ticks, not
  assume one sample per tick.

### 6.4 Timestamps on events: cost vs value

- **Free:** the state tick in every frame header stamps each event to its tick (50 ms resolution at 20 Hz, even though
  events flush every frame).
- **Sub-tick offset:** 1 byte per stamped event (1/256 of a tick, about 0.2 ms at 20 Hz) gives CS2-style precision for
  client→server actions. Cheaper than v4's 24-bit absolute stamp (3 B) and the attempt's 16-bit block stamp plus offsets.
- **Trust:** client timestamps are claims.
  - The server must derive perceived time from acks and its own interpolation settings, never from client stamps
    (`anticheat-design.md` §4.1).
  - Server→client stamps are trustworthy and useful for effect start times ("defuse started at"). Those belong in
    state fields, not event stamps, so catch-up shows them.
- Recommendation: `:timestamped()` keeps meaning "sub-tick offset relative to the frame tick", 1 B; drop absolute
  stamps.

---

## 7. Interest management at scale (Q7)

### 7.1 Techniques

- **Distance with hysteresis** (FishNet 10 %; Riot keeps actors relevant "for a small amount of time").
- **Grids and spatial hashing:** Mirror's 9-neighbour grid (cell = range/2, rebuilt every 1 s), ReplicationGraph's
  per-cell lists, Netcode for Entities' importance tiles.
- **PVS:** precomputed cell-to-cell visibility (Riot, `anticheat-design.md` §1.1); needs map data, so an extension.
- **Priority bands:** distance changes rate or priority, not membership (Iris sphere, Unreal bands).
- **Roblox's own model** is radius streaming around replication foci (`StreamingMinRadius` 64, `StreamingTargetRadius`
  1024 by default, a "standard cube" around the focus; creator-docs `workspace/streaming`).

### 7.2 Measured CPU (`interest_cost.luau`, map 4096², 30 % of entities move 4 studs/tick)

Modes:
- **brute**: all pairs.
- **grid**: cells of R, 3×3 query, exact circle with hysteresis (enter R, leave 1.1 R), enter/leave diff, membership in
  a Luau table.
- **gridbuf**: the same, with membership as a u32 stamp buffer per viewer.
- **cells**: subscribe to the 3×3 cells; work only on cell crossings.

Query ms per pass (the "move + cell" upkeep column was 0.01–0.19 ms in every mode):

| Players × entities, R=256 | rel/player | brute nat / int | grid nat / int | gridbuf nat / int | cells nat / int (rel/player) |
|---|---|---|---|---|---|
| 50 × 1,000 | 12 | 0.36 / 1.28 | 0.13 / 0.17 | 0.05 / 0.17 | 0.001 / 0.005 (34) |
| 100 × 5,000 | 62 | 1.93 / 10.8 | 0.87 / 1.07 | 0.36 / 1.03 | 0.002 / 0.011 (158) |
| 200 × 5,000 | 62 | 7.63 / 23.9 | 2.74 / 3.30 | 1.42 / 3.80 | 0.007 / 0.020 (163) |
| 200 × 10,000 | 128 | 14.5 / 41.9 | 6.61 / 5.85 | 3.85 / 5.50 | 0.009 / 0.012 (329) |
| 200 × 10,000, R=512 | 467 | 12.1 / — | 14.2 / — | 7.20 / — | 0.011 / — (1208) |

Interpretation (noise is about ±40 % between runs of the same file):
- **Exact per-viewer membership costs about 30–60 ns per candidate pair natively**, whatever the spatial index.
  - At R=512 the grid is no faster than brute force, because the relevant sets are large.
  - Hash-table membership is the main cost; a stamp buffer halves it.
- At 200 × 10,000 with R=256, exact relevancy at 10 Hz costs about 40–65 ms/s (4–7 % of a core). At the 20 Hz state
  tick it doubles.
  - The anti-cheat brief measured 0.25 ms per pass for 100 × 200 with PVS; consistent at that scale.
- **Cell subscriptions cost almost nothing**, because work scales with boundary crossings.
  - They include about 2.6× more entities (a 3R square vs a circle of R).
  - Under a byte budget that over-inclusion costs bandwidth only if those entities are dirty *and* win priority. With
    distance-scaled priority, far-in-cell entities get low weight and update rarely.
- Recommended design:
  - **Membership** by cell subscription (cell = R, 3×3, plus a one-cell hysteresis ring: leave only when two cells
    away).
  - **Priority and rate** by exact distance, computed only for pending records in the scheduler pass, which already
    touches them (§3.5).
  - **Exact visibility** (PVS, raycasts, the anti-cheat predicate) only as an extension that narrows membership at
    ≤ 10 Hz.

### 7.3 Hysteresis and churn

- Without hysteresis an entity on the boundary toggles each tick. Each toggle costs a removal plus a full catch-up
  record on re-entry: 10–30 B instead of a 3–8 B update.
- FishNet's 10 % margin and the cell ring above both suppress this. The time hold from the anti-cheat brief (`hold`
  ticks) is an alternative.
- Lync should count enters and leaves per viewer per second in its stats so churn is visible.

---

## 8. Roblox-specific constraints and opportunities (Q8)

### 8.1 Coexisting with engine replication

- **Characters and Workspace instances** replicate through the engine within the streaming radius, with physics
  ownership or Server Authority. Lync cannot hide or prioritise them (`anticheat-design.md` §1.2).
- **What Lync should replicate itself:**
  - game state that is not Instances: health, inventory, cooldowns, scores, quest and round state;
  - per-viewer secrets;
  - high-count lightweight entities that would be expensive as Instances: projectiles, NPC proxies, pickups, units;
  - anything needing per-viewer filtering or priority.
- **What to leave to the engine:**
  - Instance trees and assets;
  - physics of engine-simulated assemblies;
  - characters (unless the game renders custom rigs from Lync state);
  - predicted state under Server Authority, where attributes on predicted instances are the documented channel ("Use
    attributes to store game data that affects your core simulation", limited to the first 64 attributes, 50-char
    names and strings).
- **Server Authority implications:**
  - Client→server gameplay input should use InputActions (`landscape.md` §2.4), so Lync's `:input()` streams are for
    non-SA games and non-simulation intents.
  - Lync events are not on the simulation timeline, so Lync should expose its tick and let games bridge.
  - Do not try to compete with engine prediction.

### 8.2 Streaming

The engine streams parts around the focus, so Lync's interest focus should **default to the same focus**:
`Player.ReplicationFocus` if set, else the character's root part (documented default), keeping Lync's view consistent
with what the player sees. Lync's radius may differ (smaller for secrets, larger for minimaps). `inst()` references to
streamed-out parts arrive nil, so the nil policy (§5.3 item 5) is essential.

### 8.3 Rate limits

500 calls/s per client per remote **type**, shared with every other remote in the game. Lync sends at most one call
per lane per frame (≤ 60 + 60 at 60 Hz), so it fits, and its per-frame batching also protects the game's own remotes.
It must never fire per message.

### 8.4 Frame timing

- Frame order: input → PreRender → PreAnimation → PreSimulation → physics → PostSimulation/Heartbeat
  (`task-scheduler.md`).
- Sends run in the "Allocate Bandwidth and Run Senders" job. Its position relative to Heartbeat, and whether a remote
  fired in PostSimulation leaves in the same frame, are **undocumented**. Flushing at the end of PostSimulation (v4,
  Warp) is the common choice; whether it saves a frame over PreSimulation is an open measurement.
- With deferred signals, handlers run at the next resumption point, so receive dispatch is frame-quantized anyway.

### 8.5 Compression interacts with scheduling

- The engine compresses buffers (documented for unreliable, `UnreliableRemoteEvent.yaml`). The 1000 B limit appears to
  apply after compression (`v5-attempt.md` §9, measured there).
- A packer that fills unreliable frames to exactly 1000 B raw wastes capacity; one that fills beyond 1000 raw risks
  drops on incompressible data.
- Pack to ≤ 1000 B raw by default. Allow an opt-in "estimate" mode that uses `EncodingService:CompressBuffer` to admit
  more. That mode belongs to the compression brief.

### 8.6 Observability (needed for any budget design)

- Per definition and per player: bytes per second per lane; updates sent, deferred and demoted; mean and max pending
  age; enters and leaves.
- Per player: ack RTT and unreliable loss.
- Roblox exposes only aggregate `Stats.DataSendKbps` (`landscape.md` §5.1), so Lync's own counters are the only way a
  developer can tune `priority` and `rate`.

---

## 9. Latest work 2023–2026 (Q9)

Searched: arXiv API (netcode, interest management, game state synchronization, latency compensation, 2023+), the
Claypool/WPI publication list, GDC and Unreal and Unity sources, Roblox DevForum. Little academic work in 2023–2026
targets server-authoritative state replication. The useful advances are in engine releases.

| Item | Date | What it is | Applicability to Lync |
|---|---|---|---|
| Unity Netcode for Entities 7.x per-ghost-type snapshot history + `CalculateRecommendedSnapshotHistorySize` | 2026 (package 7.1.0) | history sized from send rate and 350 ms RTT: `ceil(0.35 × rate / interval) + 5` | sizing rule for any ack ring Lync keeps (§4.2): 20 Hz → 12 entries; Lync's 64-entry notify ring is generous |
| Unity NfE importance and `MaxSendRate` (1.4+) | 2024–2025 | per-prefab rate caps preferred over global importance floors | copy as `:rate(hz)` |
| Mirror `SyncMethod.Unreliable` | recent `master` (date unverified) | reliable 1 Hz baseline + unreliable since-baseline deltas, optional double send | simulated (§1.7): simple, no acks, but bytes grow between baselines and the baseline suffers HOL; notify is better on Lync |
| Unreal Iris (experimental through 5.x) | 2022–2026 | push dirtiness, quantized state copies, accumulated priority, capped opt-in delta baselines | model for Lync's pipeline shape (§2.1) |
| Roblox Server Authority full release | 2026-07-09 | engine prediction and rollback, InputActions, NextGenerationReplication | Lync must not compete with it; it changes ordering guarantees (§5.1) |
| Roblox UnreliableRemoteEvent 1000 B | 2025-03 | limit raised from 900 | frame sizing |
| CS2 sub-tick | 2023 | intra-tick timestamps on client actions | 1-byte sub-tick offsets (§6.4) |
| Claypool et al., peeker's advantage (FDG 2024), adaptive time delay (FDG 2024, follow-up 2026) | 2024–2026 | user studies on latency fairness; adding delay to low-latency players | game-design level; not a library feature ([peeker](https://web.cs.wpi.edu/~claypool/papers/peeker-fdg-24/paper.pdf), [adaptive](https://web.cs.wpi.edu/~claypool/papers/adaptive-fdg-26/)) |
| AFLL, arXiv 2601.10998 | 2026-01 | learns which outgoing message types cause incoming load and throttles low-priority types; 1,000 simulated players, CPU 13.2 → 6.8 ms | interesting for server CPU protection, but per-type weights already give Lync the lever; ML control loop is out of scope |
| CRDT-based P2P VR sync, arXiv 2503.17826 | 2025-03 | delta-state CRDTs for peer-to-peer | not applicable: Roblox is server-authoritative |
| Photon Fusion 2.1 custom AOI, 264 players | 2026-10 | vendor case study | shows AOI is the scaling lever; no technical detail public |

Honest assessment: nothing from 2023–2026 overturns the Tribes/Quake/Gaffer canon. The modern contributions are
engineering:
- push-model dirtiness;
- chunked or batched prioritisation;
- rate caps per type;
- history sizing;
- explicit consistency modes.
All of these are cheap to adopt in Lync.

---

## Implications

**Model per primitive and lane**

1. **Events** go on the reliable lane, flushed every frame, in call order inside the events section; not budget-limited
   but charged first. `:unreliable()` events go on the unreliable lane (newest-wins by sequence only when declared
   `:newest()`), and are dropped if still unsent past a deadline (default 1 s). (§3.7, §5.3)
2. **Requests and replies** stay reliable, every frame, outside the budget. (§3.2)
3. **Replicated state, structural parts** (add, remove, audience changes, keyframes) and **exact fields** use the
   reliable lane, delta vs last sent, encode once per partition, no acks (v4 model kept). (§1.3, §1.7)
4. **Replicated state, `:newest()` fields** use the unreliable lane:
   - absolute quantized values, encoded once per tick;
   - per-viewer dirty bits, selected by priority accumulator within the state budget;
   - repaired by ack-bitfield notify (re-dirty only what was not superseded).
   This replaces v4's no-repair streams and the attempt's settle. (§1.4, §1.7, §4.2)
5. **Delta vs acked baseline** is not core. It may come later as `:compress("acked")` on one collection, capped like
   Iris's `MaxDeltaCompressedObjectCount`. (§1.2, §2.1, §3.6)
6. **Inputs** use the unreliable lane client→server as `:input()` streams: since-ack redundancy (cap 32), delta-coded
   repeats, a server jitter buffer of 2–5 ticks adapted to arrival jitter. Not for Server Authority simulation input,
   which uses InputActions. (§4.1, §8.1)
7. **Reliable frame layout:** adds and updates → events/requests/replies → removals. Every frame carries the u16 state
   tick. (§5.3, §6.2)

**Scheduling and budget: exact knobs**

8. `stateRate` 20 Hz (10–60, a divisor of 60). Events flush every frame at PostSimulation. (§3.8)
9. `stateBudget` 16,000 B/s per player (4,000–64,000). Burst 4× for ≤ 1 s on join or audience gain. Events and replies
   are charged first; state keeps a floor of 25 % of budget. (§3.2)
10. Per-definition `:priority(w)` default 1. Owner boost ×4, first-send boost ×4. Distance factor inner 1.0 / outer 0.2
    / outside 0.1 with inner = R/4 and outer = R. The accumulator resets on send; scheduling is a 40-bucket log2 pass,
    never a comparator sort. (§3.3, §3.5)
11. Per-definition `:rate(hz)` cap for newest fields, rounded to a divisor of `stateRate`. Distance bands may halve the
    rate beyond R/2. (§3.8)
12. `maxPendingAge` 2 s starvation floor. Over budget means defer, never coarsen precision. Unreliable events past their
    deadline are dropped. (§3.4, §3.7)
13. Unreliable frame packing at ≤ 1000 B raw. Oversize single items are demoted to reliable with sequence intact.
    Schema-time worst-case size checks refuse undeclared oversize. (§4.5, §8.5)
14. Upstream ack header: `u16 tick + u32 bits` (6 B), on every upstream frame, plus a 10 Hz heartbeat when idle.
    Notify ring of 64 entries per viewer. (§4.2)
15. Client interpolation helper: delay `max(2/rate, 0.1 s) + 2 × jitterEMA`, ±2–4 % clock steering, extrapolation cap
    0.25 s. (§6.3)
16. `:timestamped()` means a 1-byte sub-tick offset on top of the frame tick. Client stamps are never trusted for
    rewind. (§6.4)
17. Optional congestion response: AIMD on the budget from ack RTT and loss (×0.7 on RTT > 1.5× min or loss > 5 %;
    +1 KB/s per second). Off by default until measured. (§3.7)

**Core vs extensions**

18. **Core:** two lanes, frame tick, ack header; reliable delta state; newest-field notify repair; dirty-list
    scheduling with accumulators, budget, `:priority`, `:rate`, `:initial`, `:owner`; `:input()` streams with since-ack
    redundancy and a fixed server buffer; the reliable frame layout; demotion; per-definition and per-player stats.
19. **Extensions (first-party, opt-in):** `:interest()` (cell subscriptions plus distance priority, cell = R, one-cell
    hysteresis ring; PVS and predicate narrowing at ≤ 10 Hz); client interpolation buffer; adaptive input-buffer
    depth; `:atTick()` event barrier; `:atomic()` consistency mode; AIMD; acked-baseline compression; `inst():await()`.
20. **Refuse:**
    - FEC/XOR parity;
    - a second reliable channel on the unreliable lane;
    - runtime precision coarsening;
    - comparator sorts in the per-viewer path;
    - per-pair relevancy without a spatial pre-filter;
    - lockstep or rollback as a Lync model.

**Open questions that need measurement on Roblox**

21. Reliable-lane retransmission timing (RTO) and HOL stall under real loss, across RemoteEvents of one connection.
    The sim's 3-tick assumption drives §1.7's reliable rows. Method: Studio `NetworkSettings` loss on client→server,
    or a real-device test with sequence-stamped frames.
22. Unreliable loss and burstiness on real Roblox connections (desktop, mobile on cellular). The sim used 1–15 %
    Bernoulli and Gilbert-Elliott with mean burst 3.
23. Whether a remote fired in PostSimulation leaves in the same frame, and the engine's actual network step rate
    (30 vs 60 Hz) on servers under load.
24. Engine replication bytes per character and per moving part, to size `stateBudget` relative to what the engine
    already uses.
25. Whether congestion shows up in Lync's ack RTT and loss before the engine drops unreliable traffic. This decides
    whether AIMD (item 17) works.
26. `GetServerTimeNow` absolute error across clients (a few ms is reported, not documented), relevant only for
    sub-tick offsets.
27. Luau costs on a Roblox server rather than the CLI: `buffer.copy` per call, table-membership cost, and the
    `interest_cost` and `sched_cost` probes under `--!native` in a live server. Client-side interpreted decode cost of
    notify frames on low-end mobile.
