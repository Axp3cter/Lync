# Lync v5: collections (milestone 4)

Draft 3.6, 2026-10-15. Part of the v5 design (`v5.md`); this file specifies milestone 4: collections, and with them
everything that decides what each viewer is shown and when: interest (§8), visibility classes (§9), scoped events
(§10), interpolation (§11), rewind (§12), and staged namespaces (§13). Wire terms (chunks, segments, `align`, EG-k,
column blocks, extended sequences, the ack) are defined in `v5.md` §4. Build-time keys (`[[pvs]]`, `[[staged]]`,
`check.*`) are in `v5-tooling.md`; decoys and their facts are in `v5-integrity.md` §8.

## 1. Model

A collection replicates keyed records (or one singleton record, with no `key`) from the server to clients. Each
case uses the model that won on the measured trade-off `[state-sync §1, Implications]`:

| What | Lane | When | Model |
|---|---|---|---|
| structure: add, remove, audience change | reliable | every flush | changes since the last flush, encoded once per unit (§3) |
| reliable fields | reliable | every flush, or at `reliableRate` | changes since the last send, encoded once per unit, no acks (ordered delivery keeps the client equal to the last sent state) |
| `:newest()` fields | unreliable | state ticks | absolute rows encoded once per tick, chosen per viewer, repaired by notify |

- **Reliable fields are sent as often as they are written** (every flush) unless the collection declares
  `reliableRate`: then field changes are coalesced and sent on flushes where ⌊(`GetServerTimeNow()` − epoch) ×
  `reliableRate`⌋ has advanced, while structure still goes every flush. With `reliableRate`, an event fired after a
  field write can arrive before that write; without it, the order is exact `[review-2 M5]`.
- **Not atomic across lanes.** A record with reliable and `:newest()` fields changes on two lanes, so `changed` can
  fire twice in one state tick. A collection that needs one change per tick declares no `:newest()` fields.
- **Unreliable means unreliable.** Unreliable *events* are never resent; only `:newest()` fields are repaired.
- **What a viewer holds** is the records in its audience (§4), narrowed by interest when the collection declares it
  (§8), with each field narrowed by its visibility class (§9). Nothing here widens an audience.

## 2. Records and slots

- **Slots.** A collection has `maxRecords` slots, ws = ⌈log2 maxRecords⌉ bits (0 for a singleton). A slot freed by
  a remove becomes reusable 2 s later. A `set` that finds no free slot throws `recordLimit` at the caller
  `[review-2 m4]`. Slots are drawn uniformly at random among free slots (server `Random`), which decoys rely on
  (`v5-integrity.md` §8).
- **Sizing `maxRecords`.** It must cover live records, records removed in the last 2 s, and the decoy pool
  (`maxPerViewer`, at most 256). At the default 1024, a 256-slot pool leaves 768; keeping 1024 for real records
  needs `maxRecords` 1280, one more bit (11) in every slot field of that collection (derived)
  `[probes security-costs #6]`.
- **Keys** travel once, in the add; everything after addresses the record by slot.
- **Decision: how a client knows which occupant of a slot a row belongs to.**
  - *Problem.* `:newest()` rows are encoded once per tick (§5) and travel on the unreliable lane, so a row can
    arrive before its record's add or after its remove. The client must apply a row only to the occupant it was
    encoded for. Draft 3.5 had both ends count adds per slot modulo 4, with the 2-bit count only in rows. But a
    row's count is the server-wide count, and a viewer that loses sight of a record and regains it (an audience
    change; with interest, constantly) receives a second add while the server-wide count is unchanged: its own
    count runs ahead, and it drops every later row of that record as older `[interest-rewind §3]`.
  - *Options:* per-viewer counts in rows (rows stop being encode-once); **the server-wide generation in every add,
    stored by the client** (2 bits per add, nothing per row); a full occupant id per row (ws + 16 bits or more on
    every row).
  - *Choice: the generation travels in the add.* The server counts adds per slot modulo 4 (`gen`, server-wide);
    every add and every row carries it, and the client stores the add's `gen` instead of counting. The fault is a
    property of the stated rules, not a measurement: milestone 4's two-sided world tests it with a record that
    leaves and re-enters one viewer's audience while other viewers keep it.
- **Row acceptance on the client.** Per slot the client keeps: whether it is occupied, the stored `gen` g and add
  tick A (the tick of the reliable frame that carried the add, `v5.md` §4.1), the extended seq s of the last applied
  row, and at most one held row. A row (gen r, frame seq q, frame tick T):
  - applies when the slot is occupied, r = g, T ≥ A and q is newer than s;
  - otherwise replaces the held row if q is newer than the held row's seq.
  - On an add (gen g, tick A) the held row applies if its gen is g and its T ≥ A, then is discarded either way.
    Rows of an occupant are only encoded after its add, so its early rows have T ≥ A, and rows of an earlier
    occupant have T < A even when its `gen` aliases (four adds of one slot are at least 8 s apart, through the 2 s
    reuse delay).
- **Reads are copy-on-write.** Each change builds the next frozen record once; `get` returns it without copying
  (7 ns against 166 ns and 320 B for clone-on-read, interpreted), and `changed` passes the previous frozen record as
  `previous` for nothing. The cost moves to applying changes: 182 ns and 320 B per changed record, interpreted
  (64 fighters at 20 Hz ≈ 0.23 ms/s and 410 KB/s of garbage) `[probes review-redundancy get_snapshot]`
  `[review-redundancy-2 R18]`.
- **Server API.** `set(key, record)` adds or replaces; `patch(key, partial)` changes fields (a misspelled key is
  `unknownPatchKey`); `remove(key)`; `audience(key, target)`; `cut(key)` (§11.3). A singleton's take no key. The
  server-view declarations `interest`, `owner`, `team`, `gate` and `rewind` are in §8, §9 and §12.
- **Client API.** `get(key)`; `interpolated(key)` (§11); signals `added(key, record)`, `changed(key, record,
  previous)`, `removed(key)`. A record changed by several chunks of one frame (§3) fires `changed` once, after the
  frame's last chunk for it, with `previous` the record before the frame.

## 3. Chunks

```
state chunk  := collection:u(wc) kind:u1 body
  kind 0     := adds updates                                                   -- column-codable rows
  kind 1     := n−1:EG0 align, then n × { slot:u(ws) mask fields align }       -- pieces, each copied on its own
adds         := n:EG0, then n rows of { slot:u(ws) gen:u2 seg:u1 key fields }  -- every field the unit carries, :newest() included
updates      := n:EG0, then n rows of { slot:u(ws) mask fields }               -- mask: 1 bit per reliable field; then the masked fields
remove chunk := collection:u(wc) n−1:EG0, then n × slot:u(ws)
rows chunk   := collection:u(wc) n−1:EG0 align, then n × { slot:u(ws) gen:u2 seg:u1 :newest() fields align }  -- state frames only
```

- wc = ⌈log2(collections in the namespace)⌉; collection indices are the namespace's collection id space, permuted
  like the others (`v5.md` §4.5). `gen` is §2's generation; `seg` is §11.3's cut bit. The wire unit owns the bit
  positions in `v5.md` §4; this grammar states what each chunk carries.
- **Units.** A chunk or piece is encoded once per *unit* and copied to every viewer the unit covers:
  - a *partition* chunk: the records sharing one audience target value (§4);
  - a *cell* chunk, under interest: the records filed in one cell, per partition (§8.4);
  - a *team* chunk: one (partition or cell, team) pair's `:team()` and fallback `:gated()` fields (§9);
  - a *piece*: one record's update, for viewers that hold it outside any shared chunk (hysteresis, a predicate,
    `:owner()` and `:seen()` fields; §8.4, §9);
  - a viewer's *own* chunk (kind 0): its catch-up adds and class transitions, encoded for that viewer alone.
- **Column coding** applies to kind 0 adds and updates of `columnMinRows` or more rows (`v5.md` §4.3). Add columns
  use the previous row as baseline; update columns use, per (record, field), the value last sent to the record's
  holders in that field's unit, which every holder has (a viewer joining a unit receives the current value in its own
  chunk first; the lane is ordered). A mask column flattens like an optional: each field's column covers the rows
  whose mask has it. Slot columns are coded like any integer column. Pieces and rows are never column-coded (§5).
- **Order inside a namespace's state chunks:** collections in index order; for each, the viewer's own chunk, then
  shared partition or cell chunks, then team chunks, then its piece chunk (kind 1, the per-viewer header followed by
  copies of the selected pieces). Removes go in remove chunks after runs (`v5.md` §4.1); a viewer may get a shared
  and an own remove chunk for one collection, and a slot appears in at most one.

## 4. Audiences and catch-up

- Each record has an audience `Target`, `Lync.all` by default. Records with the same target value share a
  partition, encoded once for all its members. Group changes apply at the next flush.
- **Catch-up.** A viewer gaining sight of a record (`WELCOME`, an audience change, entering interest) receives an
  add with every field it may see in its own chunk; losing sight is a remove. A client cannot tell "left my
  audience" or "left my interest" from "deleted". The catch-up add carries the unit's baseline (the values last
  sent to the record's holders) and precedes the shared chunks in the same frame, so the shared update applies on
  top of it.
- **No audience-by-field shortcut.** A team-partitioned game keeps one group per team; per-field visibility inside a
  record is §9's classes.
- **Interest** (§8) refines an audience per viewer and never widens it.

## 5. Decision: how `:newest()` rows are coded

- **Problem.** Notify chooses a different row subset per viewer (pending sets, budget, priority). Prediction needs a
  baseline the receiver holds; on a lossy lane that is a per-viewer acked baseline. Encoding once per tick and
  predicting exclude each other `[review-1 B3]` `[review-redundancy 3]`.
- **Measured** (`probes/design-2/newest_layout.out`; mean bytes of state per frame for one viewer):

| Model | absolute rows, encode once | per-viewer column FOR | predicted, viewer's acked baseline | predicted, partition baseline |
|---|---|---|---|---|
| shooter, 30 players, 20 Hz | 350 | 282 | 127 | 164 |
| shooter, 30 players, 60 Hz | 350 | 282 | 120 | 158 |
| shooter, 100 players, 20 Hz | 1190 | 939 | 420 | 543 |
| racing, 12 cars, 60 Hz | 243 | 227 | 152 | 173 |
| mmo, ~68 visible, 20 Hz | 249 | 172 | 57 | 83 |

- **Options:** absolute rows encoded once (1.6–4.4x the bytes of acked prediction); per-viewer column FOR (7–31%
  fewer bytes for per-viewer encoding: dominated); prediction against each viewer's acked baselines (fewest bytes;
  per-viewer encoding with a k search, history per viewer and a baseline agreement protocol); prediction against a
  partition baseline (encode once per partition, 1.1–1.45x acked prediction, no per-viewer selection, one slow
  member ages everyone's baseline).
- **Choice: absolute rows, encoded once per tick, as byte-aligned pieces copied per viewer.** Fast ranks above
  small: no history, no desynchronisation. Copying a 12 B row costs 27.6 ns native per viewer-row against 41.1 ns to
  bit-pack it per viewer `[probes review-redundancy-2 newest_rows]`; the padding costs 5.4–8% of bytes. A 100-player
  shooter's 1190 B per tick is 1.5x the default budget, so records update at about 13 Hz instead of 20. Acked
  prediction is the `acked` extension (2.3–2.8x fewer bytes on the shooters).
- **Wire.** Each record's row is encoded once per tick into its own byte-aligned piece (slot, `gen`, `seg`,
  fields); a viewer's rows chunk is the header (`collection`, count) followed by copies of the selected pieces.
  `gen` and `seg` add 3 bits per row; with byte padding that is 0 or 1 byte per row, 3/8 B on average when row
  widths are spread evenly modulo 8 (derived).

## 6. Repair (notify)

- Rows travel only in state frames, whose seq counts that viewer's state frames (`v5.md` §4.4). Per viewer, a ring
  of the last 17 state frames records which rows each carried, in a buffer (the ack covers 17 seqs). A frame is lost
  when an ack shows a newer seq received and not it; its rows become pending again unless a later frame carried
  them. A frame that leaves the ring unacked counts as lost.
- The client applies a record's row under §2's acceptance rule; both seqs are extended sequences (`v5.md` §4.4), so
  a record idle for any time is never frozen `[review-redundancy-2 1]`.
- Reordering can cause a spurious resend, never a stale value.

## 7. Scheduling and budget

- **Budget.** At each state tick the scheduler may write up to `state.budget` × Δt − charged bytes of rows to a
  player, never less than `state.floor` × `state.budget` × Δt. Δt is the time since the previous state tick (at
  most 2/`state.rate`); charged is every byte sent to that player since (reliable frames, unreliable events).
- **One rule: the largest accumulated weight goes first.** Each pending (viewer, record) has a score s. At every
  state tick while it is pending (the tick it became pending included), s += w, with
  w = `priority` × distanceFactor × ownerBoost × firstSendBoost. s resets to 0 when the row is *sent*, not acked;
  a record re-pended after a loss starts again from 0. Outside interest the three factors are 1.
  - distanceFactor (interest only), with d the distance in studs from the viewer's focus to the record's filed
    position (§8.3) and R the cell side: 1 for d ≤ R/4; 1 − 0.8 × ((d − R/4) / 0.75R)² for R/4 < d ≤ R (0.2 at R);
    0.1 for d > R (members held by hysteresis). The Iris sphere's bands `[state-sync §2.1]`.
  - ownerBoost: 4 when the collection has an `owner` binding (§9) and the viewer is the record's owner, else 1.
  - firstSendBoost: 4 for the first row after a catch-up add to that viewer, else 1. Both ×4 come from Iris
    `SphereWithOwnerBoost` and Netcode for Entities' `FirstSendImportanceMultiplier` `[state-sync §3.3]`.
  - **Age floor.** A record pending for more than 2 s (`maxPendingAge`) is taken before every other, oldest first.
    Strict weights can otherwise starve a record for as long as the weight ratio allows (1000 / 0.001 between
    `priority` bounds); 2 s is the research's floor, never reached in its simulations `[state-sync §3.4]`.
- **Two implementations of the rule.**
  - *Without interest*, w is constant per collection, so s = `priority` × age in state ticks, and one FIFO per
    collection ordered by the tick records became pending keeps them in score order: the head has the largest s.
    O(1) per step; 1.2–5.8x less CPU than accumulators with a bucket pass `[probes review-redundancy sched_fifo]`.
  - *With interest*, w changes per viewer every tick, which a FIFO can't hold. Each viewer's pending interest records
    sit in 40 buckets by b = clamp(⌊log2 s⌋ + 20, 0, 39), oldest first within a bucket; b covers s from 2^−20 (the
    smallest w, 0.001 × 0.1 ≈ 2^−13.3, after one tick) to 2^19 and above. 20–60 ns native per (viewer, pending
    record) per tick, and a comparator sort costs 3.5–7x as much `[state-sync §3.5]`. At 50% of demand the far
    records wait a mean of 1.1 ticks and p99 3, with own and near records at 0; strict priority starves them
    `[state-sync §3.4]`.
  - *One selection across both.* Each step takes the candidate with the largest key among every FIFO head (key s)
    and the oldest record of the highest non-empty bucket (key 2^(b − 20), the bucket's lower bound); ties go to the
    FIFO head, then to the lower collection index. A collection's rows are fixed-width, so once its next row doesn't
    fit none of it does, and the others continue until nothing fits.
- **Over budget** Lync defers rows (counter `rowsDeferred`) and never lowers precision. Pending is a flag, so the
  backlog is bounded by the record count `[state-sync §3.9]`.

## 8. Interest

### 8.1 What it protects, and its limit

- **What it prices.** A client can read anything Lync replicates to it: radar and ESP built on Lync records,
  loadouts, health, objectives `[anticheat-design §1.4]`. A record a client never receives can't be read, so
  per-viewer relevancy removes information instead of detecting its use. Riot's Fog of War rests on the same
  principle and runs in under 2% of server frame time `[anticheat-design §1.1]`.
- **What it can't protect.** The engine streams Workspace instances, player characters included, to every client
  whose streaming region covers them, with no line-of-sight filter `[anticheat-design §1.2]`. Interest covers only
  state Lync replicates (§13.1).
- **Optimistic by rule.** Every test errs toward sending: a pessimistic test causes pop-in for every unmodified
  client, an optimistic one leaks only inside its margin `[anticheat-design §1.4]`.

### 8.2 Declaration

`Net.fighters:interest({ … })` on the server view: interest is server policy and never ships in shared code. It
applies from the next state tick; a second call replaces the options from the tick after it. An unknown option
throws `unknownOption`, a missing required one `missingOption`, a value out of range `paramRange`, and `position`
naming no top-level field `unknownField`, or a field of another codec `fieldCodec`.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `position` | name of a top-level `t.vector3`, `t.vector3f32` or `t.cframe` field | — | — | required | none |
| `radius` | number (real) | studs | 8–4096 | required | R, the cell side. Larger means more members: about 2.6x an exact circle of R are included `[state-sync §7.2]`, so more catch-up bytes and more records in the bucket pass (20–60 ns native each, §7) |
| `lookAhead` | number (real) | s | 0–1 | 0.2 (chosen: one state tick at 20 Hz, 0.05 s, plus a one-way latency of 0.15 s, a round trip of 0.3 s; a measured round-trip distribution would change it) | one multiply-add per moving record per state tick; a record moving toward a viewer arrives up to `lookAhead` × its speed early |
| `focus` | `(player: Player) -> Vector3?` or nil | — | — | nil: §8.3's engine focus | one call per viewer per state tick |
| `pvs` | the string returned by the module `[[pvs]] output` names (`v5-tooling.md` §2), or nil | — | the bake's cell must divide R (§8.5) | nil | decoded once at the call; N_v × N_c bits of server memory (§8.5); one bit test per (viewer, cell) |
| `predicate` | `(viewer: Player, key, record) -> boolean` or nil | — | — | nil | one call per pair that passed cells and `pvs`, per `predicateRate` period; the collection's updates travel as pieces (§8.4) |
| `predicateRate` | number (real) | Hz | 1–20 | 10 (the research's ceiling for exact narrowing, "≤ 10 Hz" `[state-sync §7.2]`) | as `predicate` |

### 8.3 Membership: cells, hysteresis, look-ahead

- **Cells.** The world's XZ plane is a grid of square cells of side R; a position p is in cell (⌊p.X / R⌋,
  ⌊p.Z / R⌋). Height is ignored, so a multi-storey map over-includes: the optimistic error.
- **Filed position.** A record is filed under the cell of p + v × `lookAhead`, where p is its `position` value (a
  `t.cframe`'s position) at this state tick and v = (p − p′) × `stateRate` / (T − T′), with p′ its value at the
  previous state tick T′ this record was filed (v = 0 at its first tick). No velocity field is needed
  `[anticheat-design §1.1]` (Riot's version 3: "bigger than the expected ping time").
- **Focus.** `focus(player)` when given; otherwise `player.ReplicationFocus` when it is a `BasePart` (its
  `Position`) or a `Model` (`GetPivot().Position`), else `player.Character.PrimaryPart.Position`, else none. It is
  the engine's own streaming focus, so Lync's region and the engine's are centred on one point `[state-sync §8.2]`
  (members checked in the API dump 0.741.19: `Player.ReplicationFocus: Instance`, `Model.PrimaryPart`,
  `PVInstance:GetPivot()`). No focus keeps the viewer's last cell; a viewer that has never had one holds no
  records of the collection (treating it as "everywhere" would let a client that never spawns see every record).
- **Members.** At each state tick, a record is a member for a viewer when it is in the viewer's audience and:
  - its filed cell is in the 3 × 3 block around the viewer's focus cell, or in the ring of 16 cells around that
    block and it was a member at the previous state tick (hysteresis: it leaves only when two cells away);
  - and, with `pvs`, the (viewer, cell) bit of §8.5 is 1;
  - and, with `predicate`, the pair's last result is true (a pair never evaluated counts as true).
- **Work only on crossings.** Membership changes only when a viewer or a record changes cell, or a narrowing result
  changes. Cell upkeep at 200 viewers × 10,000 records, R = 256: 0.009 ms per pass native, 0.012 interpreted, plus
  0.01–0.19 ms of cell moves; exact per-viewer distance membership on the same load costs 3.85–6.61 ms
  `[state-sync §7.2]`. Exact distance is computed only for pending records, in §7's weights.
- **Churn.** Without hysteresis a record on a boundary toggles every tick: a remove plus a full catch-up add, 10–30 B,
  instead of a 3–8 B update `[state-sync §7.3]`. The ring bounds this to one leave per two cells of travel.
- **How it fails on an unmodified client.** A record more than one cell beyond the block's edge is withheld even in
  plain sight, so R must be at least the game's sight range for that collection; pop-in is the symptom, and
  `interestLeaves` (§14) shows its rate.

### 8.4 Decision: encoding under per-viewer membership

- **Problem.** Reliable changes are encoded once per partition and rows once per tick (§1). Under interest two
  viewers of one partition hold different subsets of its records, so a partition chunk no longer fits either.
- **Options** `[interest-rewind §3]`: per-record byte-aligned pieces copied per viewer (encode-once holds; 5.4–8%
  padding; column coding across records lost, by an unmeasured amount, §15); per-viewer encoding (48 against 25 ns
  per record native, 237 against 43 interpreted `[state-sync §3.6]`); **cell chunks**: the changes of the records
  filed in one cell, per partition, encoded once, with column coding inside the cell kept (ReplicationGraph's
  per-cell lists `[state-sync §2.1]`).
- **Choice: cell chunks, with pieces where a cell chunk doesn't fit.** Viewers with the same block hold exactly the
  same cells' records, and §8.5's PVS keeps or drops whole cells, so cell chunks survive both. Pieces carry:
  records a viewer holds only through hysteresis; every update of a collection with a `predicate` (a per-pair
  result); and `:owner()` and `:seen()` fields (§9).
- **Per flush:** each changed (cell, partition) is encoded once; a viewer's frame copies the chunks of the changed
  cells of its block for each of its partitions, then its pieces. A record moving between cells is removed or added
  only for viewers whose block covers one of the two cells and not the other; the rest take it from the new cell's
  chunk. A deleted record's remove goes in a shared remove chunk per (cell, partition), and interest leaves in the
  viewer's own remove chunk.
- **Cost:** up to 9 `buffer.copy` calls per viewer per partition per flush, at 25–44 ns each `[state-sync §3.6]`
  (0.2–0.4 µs per viewer), plus one 27.6 ns copy per piece (§5).

### 8.5 Narrowing: PVS and predicate

- **Decision: at what granularity the PVS narrows.**
  - *Problem.* The bake's cells (`[[pvs]] cell`, 8–256 studs, default 32) are finer than interest cells (R, often
    128–512). A test at bake granularity on both sides splits interest cells between viewers of one block, which
    breaks cell chunks; a test at interest granularity on both sides is too coarse to hide anything.
  - *Options:* per (viewer bake cell, record bake cell), with every PVS-narrowed record a piece (exact; encode-once
    lost for the collection); chunks per bake cell (a 3 × 3 block of R = 256 at cell 32 is 576 chunks to copy per
    viewer); **per (viewer bake cell, interest cell)**, a cell visible when any bake cell inside it is.
  - *Choice: per (viewer bake cell, interest cell).* At the `interest` call Lync derives, from the bake's N × N
    table, a table of N_v × N_c bits: bit (u, c) = OR of PVS(u, s) over the bake cells s inside interest cell c. It
    stays optimistic (a cell hides only if every part of it is hidden from the viewer's bake cell) and keeps cell
    chunks. This requires R to be an integer multiple of the bake's cell and the bake's grid to start at a multiple
    of its cell (`v5-tooling.md` §2), else the call throws `paramRange`. Cells outside the bake's extent are
    visible. Derivation cost at the call: N × N_c × (R / cell)² bit reads, about 10^6 for a 1,024-cell bake at
    R / cell = 8.
- **Bake.** Built by `lync build` or the plugin's "Bake" action, never on the edit path; only opaque collidable parts
  occlude (`Transparency == 0`, `CanCollide`); meshes, unions, terrain and moving parts never do, which keeps it
  optimistic `[interest-rewind §4.1]`. A 1,024-cell table is 128 KiB, baked in 0.17–2.16 s native on the measured
  synthetic map; 4,096 cells take 2 MiB `[interest-rewind §4.2]`. The module returns base64; Lync decodes it with
  `EncodingService:Base64Decode` (takes and returns a `buffer`; security None, checked in the API dump). Whether a
  string module of that size is accepted is unverified (§15). A PVS test costs 10.8 ns native, 61.6 interpreted
  `[interest-rewind §4.3]`.
- **Predicate.** `predicate(viewer, key, record)` runs only on pairs that passed cells and `pvs`, each pair at the
  first state tick at least 1/`predicateRate` s after its last evaluation, for game logic such as stealth or smoke.
  `false` makes the pair a non-member. A throw is reported natively as `predicateError`, a yield (re-entrancy flag)
  as `predicateYielded`, both counted in `predicateErrors`, and the pair keeps its last result (true if none): the
  optimistic rule, and the channel of `v5.md` §6.1's validators.
- **Not built: run-time raycasts per pair.** `WorldRoot:Raycast` is thread-safe (API dump) but reported at 10.7 µs
  per 2,500-stud ray from one unrepeated devforum timing; 20,000 pairs at 10 Hz would be 2–3.5 s of CPU per second
  `[interest-rewind §4.3]`. A game that wants them calls `Raycast` inside its `predicate`, which already bounds the
  rate and the pairs.

### 8.6 Decoys under interest

- **Rule.** Lync applies §8.3 and §8.5 to every decoy a behaviour returns (`v5-integrity.md` §8), with the decoy's
  own filed position (a `decoyFrom` clone of a record inside the block does not place the decoy there
  `[generation-methods M15b]`). A decoy fails, throws `decoyOutsideInterest` in the behaviour's channel (that of
  `decoyKeyLive`, a mistake in the declaration, not a fact about a player) and is removed when:
  - it is new to the viewer this state tick and its filed cell is outside the viewer's block (a real record never
    enters at ring distance, so a decoy appearing there would be the only one);
  - or it is not new and its filed cell is outside the block and its ring;
  - or the viewer's `pvs` bit for its cell is 0, or the `predicate` returns false for it.
- **Consequence.** "Beyond max draw distance" placements `[anticheat-design §2.1]` don't exist inside an interest
  collection: placements must lie within R where the game's rendering ignores them (behind the viewer, inside
  geometry, beyond the game's own render distance when shorter than R) `[interest-rewind §6.1]`.
- **Encoding.** A viewer with decoys gets its own re-encode of each changed cell chunk that holds one of its decoys,
  with the decoys' rows mixed in, and keeps shared copies for its other cells.
- **Cost:** one cell test and one PVS bit test per decoy per state tick, and the predicate's call when declared.

## 9. Visibility classes

**Problem.** A record can be visible while some of its fields should not be: enemy ammo and cooldowns, health above
a threshold, a loadout before it has been seen `[anticheat-design §1.4]`. Unreal (`COND_OwnerOnly`) and Mirror
(`syncMode` Owner) offer per-field conditions `[state-sync §2.1, §2.7]`; whole-record audiences (§4) can't.

**Declaration.** The class is a field modifier in the shared schema, because the client's type depends on it; which
viewers are in a class is bound on the server view, so policy never ships.

| Modifier (shared schema) | Server binding (server view) | A viewer receives the field when | Client type |
|---|---|---|---|
| `:owner()` | `Net.c:owner(fn(key, record) -> Player?)` | it is the record's owner | `T?` |
| `:team()` | `Net.c:team(fn(key, record) -> Target)` | it is in the record's team target | `T?` |
| `:gated()` | `Net.c:gate(field, fn(key, record) -> boolean)` | the gate returns true; or it would receive the record's `:team()` fields (with a `team` binding); or it is the owner (with an `owner` binding) | `T?` |
| `:seen()` | — | the pair has passed every narrowing test (§8.5) at some state tick since the record's last add to it; without `pvs` or `predicate`, from the add | `T?` |

- **Placement.** A modifier goes on a top-level reliable field of a collection record, one per field. Anywhere else
  (an event, a nested field, a `:newest()` field, a second modifier) is the declaration error `classPlacement`. Rows
  are one fixed-width piece per record per tick (§5), so a per-class `:newest()` field would need one row per class.
- **Hash.** Each record field gains a class byte beside its `newest` byte in the canonical serialization (0 none,
  1 owner, 2 team, 3 gated, 4 seen; `v5.md` §4.7).
- **Bindings** run once per changed record per state tick, never per viewer, and the gate once per changed record.
  A binding that throws is reported natively as `bindingError`, one that yields as `bindingYielded`, and that tick no
  viewer receives the record's fields of that class: a class exists to withhold, so the error withholds.
- **Unbound.** A modifier whose binding is missing at the first state tick where the collection holds a record is
  reported natively once (`ownerUnbound`, `teamUnbound`, `gateUnbound`, one per fix), and no viewer receives the
  field.

**Wire.** A class field is coded as `t.optional` of its codec (one presence bit), so "hidden again" decodes as nil.
Each class keeps encode-once at its own granularity:

| Class | Unit encoded once | Who receives it |
|---|---|---|
| owner | a piece per changed record | its owner |
| team | a chunk per (partition or cell, team) | the team's members holding the record |
| gated, gate true | in the public partition or cell chunk | every holder |
| gated, gate false | the team chunk with a `team` binding, and the owner piece with an `owner` binding | as those classes |
| seen | a piece per changed record | holders whose seen bit is set |

- **Transitions.** A viewer that gains a class for a record (a new owner, joining the team target, the seen bit set)
  receives the class's fields with their current values in its own chunk; one that loses it receives them as nil.
  A gate turning false sends the gated fields as nil in the public chunk and with their values in the team chunk and
  owner piece, which follow it in the frame (§3), so team members and the owner end the frame with the value and
  `changed` fires once (§2).
- **Cost.** The 4-class mask per (viewer, record) costs 19.6 ns native and 96 ns interpreted, 0.31 ms per pass for
  100 viewers × 160 relevant records `[interest-rewind §7]`; owner, team and gated are evaluated per record, so only
  `:seen()` pays per pair, with 1 bit per (viewer, slot): 12.8 KB for 100 viewers × 1,024 slots. Wire: one presence
  bit per class field per add or update carrying it.
- **What it protects, and how it fails.** It withholds field values from raw-state readers outside the class. A
  gated field reveals that its gate flipped ("health crossed 30"), by design. A `team` binding that returns the
  wrong group leaks to that group. Game UI handles nil, which `T?` enforces on both solvers and in TypeScript.
- **Decoys.** Bindings and gates run on decoy records as on real ones (`v5-integrity.md` §8), so a decoy's class
  fields reach its viewer exactly as a real record's would.

## 10. Scoped events

**Problem.** Riot's worst Fog-of-War bug class was events about an actor sent to viewers who couldn't see it, such as
the "Start Spike Defuse" RPC `[anticheat-design §1.1]`. An event fired to `Lync.all` naming an enemy's key tells
every client where that enemy is, whatever interest withholds.

**Mechanism.** `Net.hit:about("target", "fighters")` on the server view of a server-sent event: the server-sent twin
of `refers` (`v5-integrity.md` §8).
- The field is a top-level field of the event's `data` whose codec serialises (`v5.md` §4.7) identically to the
  collection's `key` codec, or `t.optional` of it. An unknown field or collection throws `unknownField`; another
  codec throws `fieldCodec`.
- At flush, each message's target is intersected with the viewers that hold the record its field names (in the
  record's audience and, with interest, a member), taken after the flush's adds and before its removes, the order of
  `v5.md` §4.1. With several `:about` calls on one definition, a viewer must hold every named record. A nil field
  scopes nothing.
- Viewers outside the intersection never receive the message; it is not queued. Each skipped (message, viewer) is
  counted in `scopedDropped` (§14): a count, not a fact, since no player's input caused it.
- **Order.** State chunks precede runs in every reliable frame (`v5.md` §4.1), so a viewer gaining sight in the same
  flush receives the catch-up add before the event, and the event never names a slot it doesn't hold.
- **Events only.** A server request names its one player, so an ask outside that player's holdings is a call game
  code made on purpose; scoping it would only turn the `invoke` into a new outcome.
- **Cost.** One holder test per (message, viewer): 10.8 ns native, 61.6 interpreted `[interest-rewind §8]`. Scoped
  messages to different holder sets become separate runs, so frames carrying them leave `FireAllClients`
  (`v5.md` §4.2); the bytes are unchanged.
- **What it protects, and how it fails.** It closes event leaks about records interest withholds. An event left
  unscoped still leaks, which the build check `unscopedRef` reports (`v5-tooling.md` §3). An effect with a duration
  ("defusing since t") must be state on the record, so catch-up shows it: an event is never repaired after a
  relevancy gap. A lint for that has no exact trigger, since the schema doesn't say what a field means, so it stays
  documentation.
