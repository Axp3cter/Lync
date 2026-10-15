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
  `[review-2 m4]`.
- **One allocator for records and decoys.** Every slot, a real record's or a decoy's (`v5-integrity.md` §8), is
  drawn uniformly at random among free slots (server `Random`) and held until its remove plus 2 s. Each viewer's
  decoys hold their own slots. A separate decoy pool marks decoys to the viewer through slot reuse: a viewer's best
  gap rule sorts them at a balanced accuracy of 0.65–1.00 with the pool, and 0.51 (chance) with one allocator
  `[refusals-rejudged-4 R16]`. Decoys hold at most `maxSlots` slots of the collection, live and in their reuse delay
  together (a `decoys` option, `v5-integrity.md` §8: how many slots the game spares for decoys is its decision); the
  cap is on the count, so every slot is still drawn uniformly. A decoy add beyond the cap, or with no free slot, is
  not made that tick (counter `decoysUnplaced`, §14) and is retried when the behaviour's next result is diffed.
- **Sizing `maxRecords`.** It must cover live records, records removed in the last 2 s, and `maxSlots`. Decoys need
  at most Σ over viewers of (live decoys + decoys removed in the last 2 s) ≤ `Players.MaxPlayers` × `maxPerViewer`
  × (1 + 2 s × r) slots, r the behaviour's replacements per decoy per second: a behaviour replacing each decoy every
  0.5 s holds 5 slots per decoy. A 64-record collection at 100 players, `maxPerViewer` 1 and r ≤ 0.2/s needs at
  least 64 + 140 slots plus the real records' reuse delay, 8 bits per slot field instead of 7: about 12 B more per
  state tick per viewer on the 100-player shooter's 1,190 B of rows, +1% (derived) `[refusals-rejudged-4 R16]`.
  Real records never wait on decoys: once `maxRecords` covers live records, their reuse delay and `maxSlots`, a real
  `set` always finds a slot.
- **Keys** travel once, in the add; everything after addresses the record by slot.
- **Decision: how a client knows which occupant of a slot a row belongs to.**
  - *Problem.* `:newest()` rows are encoded once per tick (§5) and travel on the unreliable lane, so a row can
    arrive before its record's add or after its remove. The client must apply a row only to the occupant it was
    encoded for. Draft 3.5 had both ends count adds per slot modulo 4, with the 2-bit count only in rows. But a
    row's count is the server-wide count, and a viewer that loses sight of a record and regains it (an audience
    change; with interest, constantly) receives a second add while the server-wide count is unchanged: its own
    count runs ahead, and it drops every later row of that record as older `[interest-rewind §3]`.
  - *Options:* per-viewer counts in rows (rows stop being encode-once); **the server-wide generation in every add,
    stored by the client** (2 bits per add, nothing more per row); a full occupant id per row (ws + 16 bits or more on
    every row).
  - *Choice: the generation travels in the add.* The server counts the records and decoys that have occupied
    each slot, modulo 4 (`gen`, server-wide); every add, catch-up adds included, and every row carries it, and the
    client stores the add's `gen` instead of counting. Shared decoy slots need it too: a decoy add advances the
    count, and a viewer not sent it sees only a gap, as interest produces anyway `[refusals-rejudged-4 R16]`. The
    fault is a property of the stated rules, not a measurement: milestone 4's two-sided world tests it with a record
    that leaves and re-enters one viewer's audience while other viewers keep it.
- **Ticks are full counters.** A and every tick stored below are extended ticks: the reliable header's `u16` and the
  state frame's `u8` are extended to the value nearest the client's estimate ⌊(`GetServerTimeNow()` − epoch) ×
  `stateRate`⌋, and a `RATE` keeps T continuous (its epoch is now − T / new rate), so stored ticks stay comparable
  across a rate change (`v5.md` §4.1, §4.6).
- **Row acceptance on the client.** Per slot the client keeps: whether it is occupied, the stored `gen` g and add
  tick A (the tick of the reliable frame that carried the add), the extended seq s of the last applied row, and at
  most one held row. A row (gen r, frame seq q, frame tick T):
  - applies when the slot is occupied, r = g, T ≥ A and q is newer than s;
  - otherwise replaces the held row if q is newer than the held row's seq.
  - On an add (gen g, tick A) the held row applies if its gen is g and its T ≥ A, then is discarded either way.
    Rows of an occupant are only encoded after its add, so its early rows have T ≥ A, and rows of an earlier
    occupant have T < A even when its `gen` aliases (a slot's occupants with one `gen` are at least four 2 s reuse
    delays, 8 s, apart).
- **Reads are copy-on-write.** Each change builds the next frozen record once; `get` returns it without copying
  (7 ns against 166 ns and 320 B for clone-on-read, interpreted), and `changed` passes the previous frozen record as
  `previous` for nothing. The cost moves to applying changes: 182 ns and 320 B per changed record, interpreted
  (64 fighters at 20 Hz ≈ 0.23 ms/s and 410 KB/s of garbage) `[probes review-redundancy get_snapshot]`
  `[review-redundancy-2 R18]`.
- **What an add carries.** An add's `:newest()` fields hold the record's values at the latest state tick (the
  values that tick's rows carried); a record created since that tick carries the values it was created with. So the
  add is a sample at tick A that the server holds too (§12.4).
- **Server API.** `set(key, record)` adds or replaces; `patch(key, partial)` changes fields (a misspelled key is
  `unknownPatchKey`); `remove(key)`; `audience(key, target)`; `cut(key)` (§11.3); `rebind(key)` (§9). A singleton's
  take no key. The
  server-view declarations `interest`, `owner(fn)`, `team(fn)`, `rewind` and the field handle's `gate(fn)`
  (`Net.c:field(path)`, `v5.md` §3.4) are in §8, §9 and §12.
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
    `:owner()` fields; §8.4, §9);
  - a viewer's *own* chunk (kind 0): its catch-up adds and class transitions, encoded for that viewer alone.
- **Column coding** applies to kind 0 adds and updates of `columnMinRows` or more rows (`v5.md` §4.3). Add columns
  use the previous row as baseline. Update columns of fields without a visibility class use, per (record, field),
  the value last sent to the record's holders, which every holder has (every holder receives every update of the
  record through some unit, a viewer gaining sight gets the current value in its own chunk first, and the lane is
  ordered). Class fields (§9) use the previous row, as add columns do: holders of one unit can hold different values
  of a class field (nil outside the class), so a temporal baseline would decode differently between them. A mask column flattens like an optional: each field's column covers the rows
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
  prediction is the `acked` extension (2.3–2.8x fewer bytes on the shooters); whatever coding it uses, each of its
  rows must carry `gen:u2 seg:u1` and decode to the values the truth ring holds for that tick, or §2's acceptance and
  §12's `"received"` mode no longer hold.
- **Wire.** Each record's row is encoded once per tick into its own byte-aligned piece (slot, `gen`, `seg`,
  fields); a viewer's rows chunk is the header (`collection`, count) followed by copies of the selected pieces.
  `gen` and `seg` add 3 bits per row; with byte padding that is 0 or 1 byte per row, 3/8 B on average when row
  widths are spread evenly modulo 8 (derived).
- **Downstream layouts are per build.** Per-player variants (`v5-integrity.md` §2.4) change the upstream plan and the
  tag constants only, so every unit of §3, cell chunks included, is encoded once for all players. A variant that
  varied downstream field order would need one encode per variant per unit, V times the CPU and chunk memory
  `[interest-rewind §6.2]`.

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
- **Decision: who weighs records.**
  - *Problem.* Under the budget some rows wait, and which wait (the owner's record, a near one, one just entered) is a
    judgement about the game: draft 3.6's first text fixed the Iris sphere's bands and ×4 owner and first-send boosts
    `[state-sync §2.1, §3.3]`, figures from other engines that bound no quantity of Lync's.
  - *Options:* Lync's fixed bands (cheap; Lync decides importance for every game); a table of band values (the
    developer sets numbers, Lync still fixes the shape); **a developer weight function, with Lync's selection rule
    exact around it**.
  - *Choice: the developer's weight function.* Lync keeps only what it can do exactly: accumulate, order, bound age.
- **Score.** Each pending (viewer, record) has a score s. At every state tick while it is pending (the tick it became
  pending included), s += w; s resets to 0 when the row is *sent*, not acked, and a record re-pended after a loss
  starts again from 0. w = `priority` × g, where g = `weight(viewer, key, record, distance, first)` when the
  collection's `interest` declares `weight` (§8.2), else 1. `distance` is studs from the viewer's focus to the
  record's filed position (§8.3); `first` is true for the first row after a catch-up add to that viewer. A result that
  is not a finite number in (0, 1000], a throw or a yield counts as g = 1 that tick and is reported natively as
  `weightError` or `weightYielded` (§8.7). The docs give Iris's sphere with owner and first-send boosts as an example
  function; at 50% of demand it kept far records at a mean of 1.1 ticks and p99 3, with own and near records at 0,
  where strict priority starves them `[state-sync §3.4]`.
- **Order** (one rule, exact). The candidates at each step are each collection's pending rows for the viewer.
  1. A record pending for longer than `state.maxPendingAge` (`v5.md` §7.5: real, s, 0.1–60, default 2, chosen: the
     research's starvation floor, never reached in its simulations `[state-sync §3.4]`; a game's freshness
     requirement would change it) goes before every other, oldest first.
  2. Then the largest class c = clamp(⌊log2 s⌋, −20, 19) first;
  3. within a class, the oldest pending first; then the lower collection index.
  A collection's rows are fixed-width, so once its next row doesn't fit none of it does, and the others continue
  until nothing fits.
- **Two implementations of the one rule.**
  - *Without `weight`* (with or without interest), w is constant per collection, so s = `priority` × age in state
    ticks, and one FIFO per collection, ordered by the tick records became pending, holds them in order: its head is
    its oldest and largest. O(1) per step; 1.2–5.8x less CPU than accumulators with a bucket pass
    `[probes review-redundancy sched_fifo]`.
  - *With `weight`*, w changes per pair every tick, which a FIFO can't hold: each viewer's pending records of such
    collections sit in 40 buckets by c, oldest first within a bucket. 20–60 ns native per (viewer, pending record)
    per tick for the pass, a comparator sort costing 3.5–7x as much `[state-sync §3.5]`, plus one `weight` call per
    (viewer, pending record) per tick (§8.7's thread, 119 ns interpreted on the CLI before the function's own work,
    `probes/collections-3.6/callback_thread.out`). Each step compares the FIFO heads' classes with the highest
    non-empty bucket's.
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
- **What Lync decides, and what it applies.** Lync's own membership rule (cells, hysteresis, look-ahead) errs toward
  sending: a pessimistic rule causes pop-in for every unmodified client, an optimistic one leaks only inside its
  margin `[anticheat-design §1.4]`. Its one exception is a viewer that has never had a focus (§8.3). Everything that
  needs knowledge of the game (a visibility table, a predicate, a weight, a focus) is the developer's input, which
  Lync applies exactly as given: a pair the table marks hidden is withheld, whatever the geometry.

### 8.2 Declaration

`Net.fighters:interest({ … })` on the server view: interest is server policy and never ships in shared code. It
applies from the next state tick; a second call replaces the options from the tick after it. An unknown option
throws `unknownOption`, a missing required one `missingOption`, a value out of range `paramRange`. `position` is a
path string typed as the union of the record's eligible fields (`v5.md` §3.4's rule for options naming fields), so a
wrong name is a type error; untyped, a path naming no top-level field throws `unknownField` and one of another codec
`fieldCodec`.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `position` | path string of a top-level `t.vector3`, `t.vector3f32` or `t.cframe` field | — | — | required | none |
| `radius` | number (real) | studs | 8–4096 | required | R, the cell side. Larger means more members: about 2.6x an exact circle of R are included `[state-sync §7.2]`, so more catch-up bytes and more records in the bucket pass (20–60 ns native each, §7) |
| `lookAhead` | number (real) | s | 0–1 | 0.2 (chosen: 1/`stateRate` at the default 20 Hz, 0.05 s, plus a one-way latency of 0.15 s, a round trip of 0.3 s; fixed at 0.2, not recomputed for other rates; a measured round-trip distribution would change it) | one multiply-add per moving record per state tick; a record moving toward a viewer arrives up to `lookAhead` × its speed early |
| `focus` | `(player: Player) -> Vector3?` or nil | — | — | nil: §8.3's engine focus | one call per viewer per state tick, in §8.7's thread |
| `pvs` | a table in `v5-tooling.md` §2's format: the base64 string the module `[[pvs]] output` names returns, or a `buffer` of the decoded bytes (from a bake, a `DataStore` value, or the developer's own table); or nil | — | the table's cell must divide R (§8.5) | nil | decoded once at the call; 2 × N × N_c bits of server memory, N the table's cells and N_c the interest cells it covers (§8.5); one bit test per (viewer, cell) |
| `predicate` | `(viewer: Player, key, record) -> boolean` or nil | — | — | nil | one call per pair that passed cells and `pvs`, per `predicateRate` period, in §8.7's thread; the collection's updates travel as pieces (§8.4) |
| `predicateOnError` | `"member" \| "nonMember"` | — | — | required with `predicate` (what a broken predicate should do is the game's trade between leaking and pop-in) | none |
| `weight` | `(viewer: Player, key, record, distance: number, first: boolean) -> number` or nil | — | result in (0, 1000] | nil: g = 1 (§7) | one call per (viewer, pending record) per state tick in §8.7's thread, and the bucket pass (§7) |
| `predicateRate` | number (real) | Hz | 1–20 | 10 (the research's ceiling for exact narrowing, "≤ 10 Hz" `[state-sync §7.2]`) | as `predicate` |

### 8.3 Membership: cells, hysteresis, look-ahead

- **Cells.** The world's XZ plane is a grid of square cells of side R; a position p is in cell (⌊p.X / R⌋,
  ⌊p.Z / R⌋). Height is ignored, so a multi-storey map over-includes: the optimistic error.
- **Filed position.** A record is filed under the cell of p + v × `lookAhead`, where p is its `position` value (a
  `t.cframe`'s position) at this state tick and v = (p − p′) × `stateRate` / (T − T′), with p′ its value at the
  previous state tick T′ this record was filed (v = 0 at its first tick and at the tick a `cut` takes effect,
  §11.3, so a teleport isn't filed `lookAhead` × its jump further on). No velocity field is needed
  `[anticheat-design §1.1]` (Riot's version 3: "bigger than the expected ping time").
- **Focus.** `focus(player)` when given; otherwise `player.ReplicationFocus` when it is a `BasePart` (its
  `Position`) or a `Model` (`GetPivot().Position`), else `player.Character.PrimaryPart.Position`, else none. It is
  the engine's primary streaming focus, so Lync's region and the engine's primary region share a centre
  `[state-sync §8.2]`; extra foci added with `Player:AddReplicationFocus` are the game's to pass through `focus`
  (members checked in the API dump 0.741.19: `Player.ReplicationFocus: Instance`, `Model.PrimaryPart`,
  `PVInstance:GetPivot()`, `Player:AddReplicationFocus`). No focus, or a `focus` call that throws or yields
  (`focusError`, `focusYielded`, §8.7), keeps the viewer's last cell. A viewer that has never had a focus holds no
  records of the collection, the one exception to §8.1's rule: treating it as "everywhere" would let a client that
  never spawns see every record. A game that lists records before spawn supplies `focus`.
- **Members.** At each state tick, a record is a member for a viewer when it is in the viewer's audience and:
  - its filed cell is in the 3 × 3 block around the viewer's focus cell, or in the ring of 16 cells around that
    block and it was a member at the previous state tick (hysteresis: it leaves only when two cells away);
  - and, with `pvs`, the (viewer, cell) *enter* bit of §8.5 is 1, or the pair was a member at the previous state
    tick and the *stay* bit is 1;
  - and, with `predicate`, the pair's last result is true (a pair is first evaluated at the state tick it passes
    cells and `pvs`).
- **Work only on crossings.** Membership changes only when a viewer or a record changes cell, or a narrowing result
  changes. Cell upkeep at 200 viewers × 10,000 records, R = 256: 0.009 ms per pass native, 0.012 interpreted, plus
  0.01–0.19 ms of cell moves; exact per-viewer distance membership on the same load costs 3.85–6.61 ms
  `[state-sync §7.2]`. Exact distance is computed only for pending records, for `weight`'s `distance`.
- **Churn.** Without hysteresis a record on a boundary toggles every tick: a remove plus a full catch-up add, 10–30 B,
  instead of a 3–8 B update `[state-sync §7.3]`. The ring bounds this to one leave per two cells of travel.
- **How it fails on an unmodified client.** A record more than one cell beyond the block's edge is withheld even in
  plain sight, so R must be at least the game's sight range for that collection; pop-in is the symptom.
  `interestEnters` (§14) counts how often records appear for a viewer; the distance at entry is not reported.

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
  result); and `:owner()` fields (§9).
- **Per flush:** each changed (cell, partition) is encoded once; a viewer's frame copies the chunks of the changed
  cells of its block for each of its partitions, then its pieces. A record moving between cells is removed or added
  only for viewers whose block covers one of the two cells and not the other; the rest take it from the new cell's
  chunk. A deleted record's remove goes in a shared remove chunk per (cell, partition), and interest leaves in the
  viewer's own remove chunk.
- **Cost:** up to 9 `buffer.copy` calls per viewer per partition per flush, at 25–44 ns each `[state-sync §3.6]`
  (0.2–0.4 µs per viewer), plus one 27.6 ns copy per piece (§5).

### 8.5 Narrowing: PVS and predicate

- **What Lync guarantees.** A pair is withheld iff the table's bit for it is 0 (with the stay rule below) or the
  predicate's last result is false. Lync applies the table and the predicate exactly as given; whether either matches
  what a player can see is the developer's, who reviews, edits or replaces the baked table, or supplies their own
  (`v5-tooling.md` §2: an entry without `place` reads the developer's table as is).
- **The bake is an approximation with errors in both directions** (`v5-tooling.md` §2): a pair is marked hidden iff
  every segment between its cells' sample points, at one eye height, crosses an opaque collidable box
  `[interest-rewind §4.1–§4.2]`. Meshes, unions, terrain and moving parts never occlude, which errs toward visible;
  an opening narrower than the sample spacing (`cell` / `samples`), and any view over a wall from a height, can be
  marked hidden, which errs toward withholding: a 2-stud opening between two 32-stud cells at 2 × 2 samples is
  marked hidden while the line through it is clear (`probes/scope-3.6/pvs_gap.luau`). A 1,024-cell table is
  128 KiB, baked in 0.17–2.16 s native on the measured synthetic map; 4,096 cells take 2 MiB `[interest-rewind
  §4.2]`. A base64 string is decoded with `EncodingService:Base64Decode` (takes and returns a `buffer`; security
  None, checked in the API dump); whether a string module of that size is accepted is unverified (§15), so `pvs`
  also takes the decoded `buffer`, from a `DataStore` value (at most 4,194,304 characters per key, documented) or
  any source.
- **Decision: at what granularity the table narrows.**
  - *Problem.* The table's cells (`[[pvs]] cell`, 8–256 studs, default 32) are at most as large as interest cells
    (R ≥ the table's cell, below). A test at table granularity on both sides splits interest cells between viewers of
    one block, which breaks cell chunks; a test at interest granularity on both sides is too coarse to hide
    anything.
  - *Options:* per (viewer table cell, record table cell), with every narrowed record a piece (encode-once lost for
    the collection); chunks per table cell (a 3 × 3 block of R = 256 at cell 32 is 576 chunks to copy per viewer);
    **per (viewer table cell, interest cell)**, an interest cell visible when any table cell inside it is.
  - *Choice: per (viewer table cell, interest cell).* At the `interest` call Lync derives from the table's N × N bits
    an *enter* table of N × N_c bits, enter(u, c) = OR of PVS(u, s) over the table cells s inside interest cell c,
    and keeps cell chunks. Each is an exact function of the given table. It requires R to be an integer multiple of
    the table's cell and the table's grid to start at a multiple of its cell, else the call throws `paramRange`.
    Cells outside the table's extent are visible. Derivation cost at the call: N × N_c × (R / cell)² bit reads,
    about 10^6 for a 1,024-cell table at R / cell = 8.
- **Decision: hysteresis for the table.**
  - *Problem.* Without it, a viewer standing on a table-cell boundary, between a cell from which interest cell c is
    visible and one from which it is hidden, removes and re-adds every record of c at each crossing (10–30 B each,
    §8.3), the churn the cell ring exists to prevent, at a granularity R / cell times finer.
  - *Options:* none (churn at boundaries); a time hold (ticks a pair stays after its bit turns 0: a second clock, and
    still churn at the hold's period); **a stay table, as cells have a ring**.
  - *Choice: a stay table.* stay(u, c) = OR of enter(u′, c) over u and its 8 neighbouring table cells, derived at the
    call (another N × N_c bits, 9× the reads). A pair enters only when enter(u, c) is 1 and stays while stay(u, c)
    is 1. A viewer moving back and forth across one table boundary never toggles a cell. Leak margin: a cell stays
    held for up to one table cell (`cell` studs) of viewer travel after it is hidden. A PVS test costs 10.8 ns native,
    61.6 interpreted `[interest-rewind §4.3]`.
- **Predicate.** `predicate(viewer, key, record)` runs on pairs that passed cells and the table, first at the state
  tick the pair passes them, then each pair at the first state tick at least 1/`predicateRate` s after its last
  evaluation, for game logic such as stealth or smoke. `false` makes the pair a non-member. A throw
  (`predicateError`) or a yield (`predicateYielded`), both counted in `predicateErrors`, gives the pair
  `predicateOnError`'s result for that evaluation (§8.7).
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
  - or the viewer's `pvs` enter bit for its cell is 0 (new) or its stay bit is 0 (not new), or the `predicate`
    returns false for it.
- **Consequence.** "Beyond max draw distance" placements `[anticheat-design §2.1]` don't exist inside an interest
  collection: placements must lie within R where the game's rendering ignores them (behind the viewer, inside
  geometry, beyond the game's own render distance when shorter than R) `[interest-rewind §6.1]`.
- **Encoding** (with or without interest). A viewer's copy of a changed shared chunk (partition or cell) is
  re-encoded, with its decoys' rows mixed in, only in a flush where its decoys have adds or updates in that chunk;
  otherwise it gets the shared chunk, and stays in `FireAllClients` for that flush if nothing else is per viewer.
  The re-encode runs the full k search, so it is the minimal encoding of its rows, as every shared chunk is
  (`v5.md` §4.3); reusing the shared chunk's k leaves non-minimal encodings (+4 B at 16 decoys, +152 B at 256), a
  mark, and is not used. A decoy's remove goes in the viewer's own remove chunk. Cost: 19.3 µs native per re-encode
  at one decoy; a behaviour that moves only `:newest()` fields and replaces its decoy every 5 s pays 3.9 µs/s per
  viewer `[refusals-rejudged-4 R16]` `[probes security-costs #6]`.
- **Cost:** one cell test and one PVS bit test per decoy per state tick, and the predicate's call when declared.

### 8.7 Game callbacks

- **Problem.** `focus`, `predicate`, `weight`, the class bindings and gates (§9) are game code that Lync calls during
  its state tick. Luau lets a coroutine yield across `pcall`, so a callback that yields (`task.wait`, `WaitForChild`)
  run on Lync's own thread suspends the whole tick: every player's frames stay unsent, and when the wait ends the
  old tick resumes against state later ticks changed. A re-entrancy flag sees it only at the next entry (checked,
  `luau.py run`, Luau 0.740, by the review; `probes/collections-3.6/callback_thread.out`).
- **Options:** a fresh thread per call (`coroutine.create`, then `resume`; 250–264 ns per call interpreted on the
  CLI, the callback's own work excluded); **a pooled thread per call site, replaced after a yield or throw** (one
  `resume`, 119 ns); `pcall` on Lync's thread (44 ns; can't detect a yield in time).
- **Choice: a pooled thread per call site.** Each call resumes the site's thread with the callback and its
  arguments; the thread runs the callback, sets a done flag and yields the result back. After `resume`:
  - `false` from `resume`: the callback threw. Lync reports `<site>Error` natively with its message (spacing of
    `v5.md` §7.2) and makes a new thread for the site;
  - `true` with the done flag unset: the callback yielded. Lync reports `<site>Yielded`, abandons the thread (it is
    never resumed or closed by Lync; whatever it returns when the engine resumes it is discarded) and makes a new
    one;
  - otherwise the result is used.
  Either fault gives the call its declared fallback at once, in the same tick: `focus` keeps the viewer's last cell,
  `predicate` takes `predicateOnError`, `weight` counts as 1, a binding or gate takes its `onError` (§9). Codes:
  `focusError`/`focusYielded`, `predicateError`/`predicateYielded`, `weightError`/`weightYielded`,
  `bindingError`/`bindingYielded`. Checked on the CLI: normal, yielding and throwing callbacks give `ok`,
  `yielded` and `threw`, and the next call after a yield runs on a new thread.
- **Cost.** One `resume` per call, 119 ns interpreted on the CLI (unmeasured native and on Roblox, §15); one thread
  allocation per fault.

## 9. Visibility classes

**Problem.** A record can be visible while some of its fields should not be: enemy ammo and cooldowns, health above
a threshold `[anticheat-design §1.4]`. Unreal (`COND_OwnerOnly`) and Mirror (`syncMode` Owner) offer per-field
conditions `[state-sync §2.1, §2.7]`; whole-record audiences (§4) can't.

**Declaration.** The class is a field modifier in the shared schema, because the client's type depends on it; which
viewers are in a class is bound on the server view, so policy never ships.

| Modifier (shared schema) | Server binding (server view) | A viewer receives the field when | Client type |
|---|---|---|---|
| `:owner()` | `Net.c:owner(fn(key, record) -> Player?, { onError })` | it is the record's owner | `T?` |
| `:team()` | `Net.c:team(fn(key, record) -> Target, { onError })` | it is in the record's team target | `T?` |
| `:gated()` | `Net.c:field(path):gate(fn(key, record) -> boolean, { onError })` | the gate returns true; or it would receive the record's `:team()` fields (with a `team` binding); or it is the owner (with an `owner` binding) | `T?` |

- **No `:seen()` class.** IR §7 defined a fourth class, a field sent once the pair "passed the narrowing test", but
  every member has passed it when it is added (§8.3), so the class withheld nothing while paying a per-pair bit, piece
  encoding and a presence bit. A correct form needs a game test narrower than membership: a second per-pair
  predicate with its own rate. Per-viewer withholding of whole records already exists exactly: a game keeps such
  fields (a loadout) in a second collection whose `audience` it sets to the viewers that have seen the owner.
- **Placement.** A modifier goes on a top-level reliable field of a collection record, one per field. Anywhere else
  (an event, a nested field, a `:newest()` field, a second modifier) is the declaration error
  `visibilityPlacement` (`v5.md` §3.3). Rows are one fixed-width piece per record per tick (§5), so a per-class
  `:newest()` field would need one row per class.
- **Hash.** Each record field gains a class byte beside its `newest` byte in the canonical serialization (0 none,
  1 owner, 2 team, 3 gated; `v5.md` §4.7).
- **When bindings run.** A binding or gate is evaluated, in §8.7's thread, for a record before its add is first
  encoded, when the record changes, and after `Net.c:rebind(key)` (server), at the next state tick, never per viewer.
  It must read only `key` and `record`; anything else it reads (a player's `Team`, a seat's occupant, a round state)
  changes nothing until the game calls `rebind(key)`, the exact trigger the game owns. Cost: one call per binding per
  changed or rebound record per state tick.
- **On error.** `onError` (`"include" | "exclude"`, required: what a broken binding should do is the game's trade
  between leaking and withholding) is the result of a throw or yield (`bindingError`, `bindingYielded`, §8.7):
  `"include"` gives the class to every holder of the record for that evaluation, `"exclude"` to none. The wire
  effect is the transition from the previous result (below), as for any other change of result.
- **Unbound.** A modifier whose binding is missing at the first state tick where the collection holds a record is
  reported natively once (`ownerUnbound`, `teamUnbound`, `gateUnbound`, one per fix), and no viewer receives the
  field.

**Wire.** A class field is coded as `t.optional` of its codec (one presence bit), so "hidden again" decodes as nil.
Each class keeps encode-once at its own granularity; class fields' update columns use the previous row as baseline
(§3):

| Class | Unit encoded once | Who receives it |
|---|---|---|
| owner | a piece per changed record | its owner |
| team | a chunk per (partition or cell, team) | the team's members holding the record |
| gated, gate true | in the public partition or cell chunk | every holder |
| gated, gate false | the team chunk with a `team` binding, and the owner piece with an `owner` binding | as those classes |

- **Transitions.** A viewer that gains a class for a record (a new owner, joining the team target) receives the
  class's fields with their current values in its own chunk; one that loses it receives them as nil. A gate turning
  false sends the gated fields as nil in the public chunk and with their values in the team chunk and owner piece,
  which follow it in the frame (§3), so team members and the owner end the frame with the value and `changed` fires
  once (§2).
- **Cost.** The class mask per (viewer, record) costs 19.6 ns native and 96 ns interpreted, 0.31 ms per pass for
  100 viewers × 160 relevant records, measured with four classes `[interest-rewind §7]`; owner, team and gated are
  evaluated per record. Wire: one presence bit per class field per add or update carrying it.
- **What it protects, and how it fails.** It withholds field values from raw-state readers outside the class. A
  gated field reveals that its gate flipped ("health crossed 30"), by design. A `team` binding that returns the
  wrong group, or reads state the record doesn't hold without a `rebind`, leaks to that group. Game UI handles nil,
  which `T?` enforces on both solvers and in TypeScript.
- **Decoys.** Bindings and gates run on decoy records as on real ones (`v5-integrity.md` §8), so a decoy's class
  fields reach its viewer exactly as a real record's would.

## 10. Scoped events

**Problem.** Riot's worst Fog-of-War bug class was events about an actor sent to viewers who couldn't see it, such as
the "Start Spike Defuse" RPC `[anticheat-design §1.1]`. An event fired to `Lync.all` naming an enemy's key tells
every client where that enemy is, whatever interest withholds.

**Mechanism.** `Net.hit:field("target"):about(Net.fighters)` on the server view of a server-sent event: the
server-sent twin of `field(path):refers(collection)` (`v5-integrity.md` §8).
- The handle's field has the collection's key type, or `t.optional` of it: another type is a type error on both
  solvers and in TypeScript (`v5.md` §3.4); untyped, a field whose codec doesn't serialise (`v5.md` §4.7)
  identically to the collection's `key` codec throws `fieldCodec`, and an unknown path `unknownField`.
- At flush, each message's target is intersected with the viewers that hold the record its field names (in the
  record's audience and, with interest, a member), taken after the flush's adds and before its removes, the order of
  `v5.md` §4.1. With `about` on several fields of one definition, a viewer must hold every named record. A nil field
  scopes nothing.
- Viewers outside the intersection never receive the message; it is not queued. Each skipped (message, viewer) is
  counted in `scopedDropped` (§14): a count, not a fact, since no player's input caused it.
- **Order.** For a reliable event: state chunks precede runs in every reliable frame (`v5.md` §4.1), so a viewer
  gaining sight in the same flush receives the catch-up add before the event. An unreliable scoped event travels in
  an event frame, which can arrive before the reliable add of the record it names; `get(key)` is nil then.
- **Events only.** A skipped event message needs nothing more: events have no reply. A skipped ask would need a new
  outcome in `invoke`'s result, a second way for the invoking code to learn what it can already read, since it
  names the one player itself. `unscopedRef` covers server-sent events only (`v5-tooling.md` §3, Needs elsewhere).
- **Cost.** One holder test per (message, viewer): 10.8 ns native, 61.6 interpreted `[interest-rewind §8]`. Scoped
  messages to different holder sets become separate runs, so frames carrying them leave `FireAllClients`
  (`v5.md` §4.2); the bytes are unchanged.
- **What it protects, and how it fails.** It closes event leaks about records interest withholds. An event left
  unscoped still leaks, which the build check `unscopedRef` reports (`v5-tooling.md` §3). An effect with a duration
  ("defusing since t") must be state on the record, so catch-up shows it: an event is never repaired after a
  relevancy gap. A lint for that has no exact trigger, since the schema doesn't say what a field means, so it stays
  documentation.

## 11. Interpolation

The client renders `:newest()` fields a delay D behind the newest state it received, between the samples it holds.
Rewind (§12) needs D exactly, so it is part of the protocol.

### 11.1 Decision: who chooses the delay

- **Problem.** D sets how far behind the present a client renders, so it is part of the tick the client perceives.
  Draft 3.5 had the client adapt D from its own arrival jitter. Whatever the client chooses, the server must take
  its word for, and a client-chosen D is a client-stated rewind offset bounded by a formula: R20 again
  `[interest-rewind §11.3]`.
- **Options:** the client adapts D (smallest buffer for its own link; the server trusts it); one fixed D for every
  player (no adaptation: underruns on jittery links, needless delay on clean ones); **the server computes D per
  player from its own estimate and sends it**.
- **Choice: the server chooses D.** It sees both directions in its ack round trip, so its jitter errs toward a
  longer delay, never a shorter one.
- **Timing estimates, per player** (server, `os.clock()` throughout, the one clock of every server timing,
  `v5-3.6-inputs.md` §4 #28):
  - a sample per state frame n: (arrival of the first upstream frame whose ack names n as its newest seq) − (n's
    send time). Taking only the newest seq of each ack keeps the client's ack delay at one client flush: a client with
    data acks at its next flush, and an idle one when a second unacked frame arrives (`v5.md` §4.1), naming that
    frame. At `stateRate` 10 the ack-only 100 ms timeout and the second frame coincide, so an idle client's samples
    split between rtt and rtt + 100 ms: jitter near 50 ms, and D up to 0.1 s longer than for the same link with an
    active client (derived). The server can't tell which trigger sent an ack-only frame, so samples aren't
    filtered; the error is toward a longer delay;
  - over the samples of the last 5 s: ackRtt = their minimum, jitter = their mean absolute deviation from their
    mean. 5 s is chosen, unmeasured: it is the beacon estimator's window (`v5.md` §4.9); a longer one reacts more
    slowly to a route change, a shorter one is noisier. With no sample in the window both keep their last values.
- **D, exactly.** Target = max(2 / `stateRate`, `interpolation.delayFloor`) + `interpolation.jitterFactor` ×
  jitter, in units of 4 ms rounded up, at most 255 units (1.02 s). The 2 / `stateRate` term keeps two state ticks
  buffered, so a next sample exists; how much delay to trade for smoothness above it is the game's, set with two
  `Lync.configure` options (`v5.md` §7.5):

  | Option | Type | Unit | Range | Default | Cost |
  |---|---|---|---|---|---|
  | `interpolation.delayFloor` | number (real) | s | 0–1 | 0.1 (chosen: Source's `cl_interp` `[state-sync §6.3]`; a game's latency target would change it) | every rendered `:newest()` field is that much older |
  | `interpolation.jitterFactor` | number (real) | multiple of jitter | 0–8 | 2 (chosen: the research's k `[state-sync §6.3]`; 0 gives every player the fixed floor) | D grows by that multiple of the player's jitter |

  Once a second per player, D moves one unit toward the target. D starts at D₀ = ⌈max(2 / `stateRate`,
  `interpolation.delayFloor`) / 0.004⌉ units, sent in the connection's first `WELCOME` (`v5.md` §4.6); a
  `stateRate` or option change sets D = max(D, the new D₀) at once.
- **Wire.** `RATE` gains `delay u8` (D in 4 ms units) and goes to one player whenever its D changes, besides every
  `stateRate` change; the client applies it when it decodes the frame, and the server reads which D was in
  force for a message from the receipt (§12.3). Cost: at most one `RATE` row (78 bits of fields) per player
  per second. The unit and step are protocol constants: u8 × 4 ms covers jitter up to 0.41 s at 10 Hz, and one unit
  a second changes the playback rate by 0.4%, below `GetServerTimeNow()`'s own 0.6% rate bound `[state-sync §6.1]`
  (chosen, unmeasured for visibility). Whatever rule produced it, the D in force for a message is the one Lync
  sent, and rewind uses that (§12.3).

### 11.2 The rendering clock and sampling

- **Target tick.** τ* = T_n + (c − a_n) × `stateRate` − D × `stateRate`, where n is the newest state frame received
  (largest extended seq), T_n its tick, a_n its arrival on the client's `os.clock()` and c the time now. This is the
  quantity §12.3 reconstructs on the server.
- **Clock.** Once per client frame, at `RunService.PreRender`, the render tick τ follows τ*: e = τ* − τ; if |e| >
  0.25 × `stateRate` or τ is unset, τ = τ*; otherwise τ advances by Δt × `stateRate` × (1 + 0.04 × sign(e)) when |e|
  is more than one client flush (`stateRate` / 60 ticks), and by Δt × `stateRate` otherwise. Catching up or slowing
  by 4% instead of jumping is the research's recommendation (chosen: Mirror's 2–4%, the upper end; unmeasured here)
  `[state-sync §6.3]`; the snap threshold is the extrapolation cap, beyond which the buffer is empty anyway. These
  stay constants: the slew is client-side smoothing whose deviation from τ* §12.9 states, and the cap must be the
  same on both ends for rewind to reproduce the sampling; a game wanting other rendering interpolates itself and sets
  `rewind`'s `delay` (§11.4).
- **Samples.** Per record, the client keeps (tick, `:newest()` values, `seg`) for its add and for every row of the
  current occupant that arrives (gen = g and T ≥ A, §2), in tick order, whether or not its seq is newer than the one
  `get` reflects: the newest sample at or before τ and every later one, at most ⌈D × `stateRate`⌉ + 2 (derived from
  the rows a record can receive in D). So the client's samples are exactly the rows it received, which acks report
  (§12.4).
- **Sampling at τ** (the same function on the server in §12.4). a is the newest sample with tick ≤ τ, b the next:
  - a and b with equal `seg`: each field at α = (τ − T_a) / (T_b − T_a);
  - a and b with different `seg` (a cut between them): a's values;
  - no b: from the two newest samples when their `seg` is equal, at α for min(τ, T_newest + 0.25 × `stateRate`),
    else the newest's values. The 0.25 s extrapolation cap is chosen: Source's `cl_extrapolate_amount`
    `[state-sync §6.3]`, unmeasured here;
  - no a: the oldest sample's values.
- **Per codec:** `t.vector3`, `t.vector3f32`, `t.number`, `t.f32`, `t.f64` and a `t.cframe`'s position lerp;
  `t.angle` lerps along the shorter arc; `t.rotation`, `t.direction` and a `t.cframe`'s rotation nlerp; every other
  field takes a's value. α above 1 extrapolates with the same formulas.

### 11.3 Cuts

- **Problem.** A teleport or respawn between two samples interpolates through the space between. The client must
  know a cut happened between two samples it holds even when the rows around it were lost or deferred, and rows are
  encoded once for every viewer.
- **Options:** a list of cut slots in reliable state chunks (ordered with the reliable lane, not with rows, so a row
  after the cut can be interpolated before the list arrives); per-viewer "cut pending" flags in rows (breaks
  encode-once); **a per-record segment bit in every add and row**, flipped by each cut.
- **Choice: the segment bit.** `Net.c:cut(key)` flips the record's `seg` at the next state tick (several calls before
  one state tick flip it once). Samples with different `seg` are never interpolated together (§11.2), on the client
  or in rewind. Cost: 1 bit per add and per row (inside §5's 3/8 B mean). Limit: two cuts at different ticks between
  two samples one viewer receives leave `seg` equal, and that viewer interpolates across both; stored values are
  never affected, only rendering between them.

### 11.4 API and cost

- **`Net.c:interpolated(key)`** (client) returns a frozen record: reliable fields as `get` returns them,
  `:newest()` fields sampled at τ. It returns nil when `get` does.
- **Cost.** Per call, one frozen record (320 B for the 6-field fighter, as §2's clone) and one sample per
  `:newest()` field. Unmeasured on the client; the nearest probes are the server's position-only lerp at 141–146 ns
  interpreted and a bracket-lerp with two rotation decodes at 389–437 ns `[interest-rewind §11.7]`. Memory: §11.2's
  samples per record. Wire: §11.1's `RATE` and §11.3's bit.
- **A game with its own interpolation** reads `get` with `Lync.tick()` (the dispatched frame's tick) in `changed`,
  and sets `rewind`'s `delay` to the constant it uses (§12.2); Lync can't see its clock.

## 12. Rewind

### 12.1 What it protects, and what it is not

- **The claim it prices.** A client says "I hit record k" or "I fired from here". The server must judge that against
  the state *that client was shown*, or every unmodified client with latency misses (Bernier's lag compensation
  `[anticheat-design §4.1]`).
- **The flaw it removes.** Community rewind libraries take the rewind time from the client, clamped to a window: a
  free choice of any past position inside it, the "backtrack" advantage, which R20 refuses `[interest-rewind §11.1]`.
  Lync sent every state frame and receives every ack, so it derives the tick from its own frames, the engine's ping
  and the server-chosen D (§11.1), never from a client-stated time.
- **What it is not.** Lync returns state at a tick. The hit test, its tolerance, world occlusion (Roblox can't rewind
  geometry) and anything done about a miss are the game's (R36). Lync can't know a message is a hit claim, so rewind
  states no `Lync.observe` fact; its evidence is in the values the game asks for.

### 12.2 Declaration and rings

`Net.fighters:rewind({ … })` on the server view; nothing enters the schema hash. Option errors as §8.2; a `fields`
entry that is not a top-level field is `unknownField`, and one whose codec has no fixed single-row width (strings,
buffers, arrays, maps, optionals, unions) or that has a visibility class (§9: its value differs per viewer) is
`fieldCodec`.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `fields` | array of top-level field path strings, typed as a union of the record's fields | — | — | every `:newest()` field | per record: each field's single-row width rounded up to bytes, × K |
| `maxRewind` | number (real) | s | 0.1–2 | 1 (chosen, unmeasured: P lies about rtt + D behind the present, so 1 s covers round trips up to 1 s − D; a measured ping distribution would change it) | K = ⌈(`maxRewind` + 0.25) × `stateRate`⌉ + 2 slots per record; L = K + 17 map entries per player |
| `mode` | `"received" \| "truth"` | — | — | `"received"` (derived: equal to truth when the viewer got every row, and truth is off by p99 1.33 studs once a third of rows are deferred, §12.4; the bracket it used is returned, §12.5) | received: ⌈K / 8⌉ B per (viewer, record) and 8.3–8.8 ns native per acked row |
| `delay` | number (real) or nil | s | 0–1 | nil: the player's server-chosen D (§11.1) | none |

- **Truth ring.** One slot per record per state tick, written after the tick's rows are encoded, for every tracked
  record changed or not, so a read is an index, never a search: 4 B state tick (u32; a slot is valid only for the
  tick asked for), 12 B position as three f32 (the *decoded quantized* value the row carried, which is what clients
  saw; a `t.vector3(-2048, 2048, 1/32)` value is exact in f32), the rotation's code rounded up to bytes (4 B for `t.rotation(9)`'s
  30 bits, 5 B for `t.rotation(12)`'s 38; decoded only when queried), 1 B holding the `seg` bit and up to 7 boolean fields, 3 B padding: 24 B for a position, a `t.rotation(9)` and
  booleans. Other declared fields add their single-row width rounded up; reliable fields hold their value as of that
  tick's flush. A record created after a state tick's rows were encoded gets that tick's slot at creation, holding
  the values it was created with (its add's sample, §2). K covers the window,
  the 0.25 s extrapolation cap and the two lerp neighbours `[interest-rewind §11.2]`.
- **Per player:** a map from state-frame seq to (state tick, send time), L entries of 12 B (the notify ring's 17 plus
  K); and, for each downstream reliable frame of the last max(2 s, `maxRewind` + 0.25 s), its count, send time and
  state tick.
- **Per (viewer, record):** the reliable-frame counts of its adds and removes for that viewer over the same span
  (who held what, §12.3); in `"received"` mode, one bit per truth-ring slot, set when an acked state frame carried
  that tick's row to the viewer or the viewer's add landed on that tick: K bits (4 B at 20 Hz and `maxRewind` 1 s),
  covering the whole window whatever D is, so a stored `seen` stays usable while its ticks are in the ring.
- A `stateRate` change restarts the rings; earlier ticks return `expired`.

### 12.3 Decision: how the perceived tick is established

- **Problem.** The client shows `:newest()` fields D behind (§11.2) and reliable fields as soon as their frame is
  decoded, so a message needs two ticks, and the server must find both without trusting a client-stated time. Today
  only the first frame of a flush carries a full ack (`v5.md` §4.1): with `'0'` the server would use the newest ack
  it holds, which may come from a lost unreliable frame (P too old) or from a frame on the other lane that arrived
  first (P too new).
- **Options:** the client states its render tick (R20: refused); the server takes the newest ack it holds (wrong
  across lanes, as above); **each frame names its own state: a full ack for `:newest()` fields and the reliable
  receipt `rcv` (`v5.md` §4.1) for reliable ones**.
- **Choice: the frame's own ack and receipt.** A client definition declared `perceived = true` (shared schema,
  hashed, since the client acts on it) makes every upstream frame holding one of its messages carry `'1' seq
  received` whenever any state frame has arrived. Cost: 28 bits on each such frame that would have carried `'0'`, at
  most 35 B/s up at 10 claim frames a second. Undeclared definitions can still be rewound; when
  their frame carried `'0'`, `ackExact` is false.
- **Inputs, for a message in upstream frame f from player p** (server `os.clock()` seconds), all per frame and
  per player:
  - t_r, when f was decoded;
  - s, f's ack (else the newest ack held from p), T_s its state tick, t_s its send time. With no state frame ever
    received from Lync, s is none: `ackSeq` is −1 and every `rewound` gives `"expired"`;
  - ping = `p:GetNetworkPing()` at f's decode (round trip, "isolated network latency … doesn't involve data
    deserialization or processing", documented); rtt = clamp(ackRtt, ping, ping + `rewind.rttSlack`), ackRtt and
    jitter from §11.1. `rewind.rttSlack` is a `Lync.configure` option (`v5.md` §7.5), since it bounds a per-player
    estimate, not a collection's property:

    | Option | Type | Unit | Range | Default | Cost |
    |---|---|---|---|---|---|
    | `rewind.rttSlack` | number (real) | s | 0–0.2 | 0.05 (derived floor 2/60 = 0.033 s, Lync's processing of one client flush and one server frame on top of engine ping; the margin above it chosen) | none; bounds how far the ack round trip may raise engine ping |

  - H, the reliable horizon: f's extended `rcv` when f is a reliable frame, or an unreliable frame holding a
    `perceived` message, which then carries `rcv` too (`v5.md` §4.1; `receivedExact` true). Otherwise H is estimated
    as the count of reliable frames sent to p at or before t_r − rtt (`receivedExact` false): an estimate that is too
    new during a reliable-lane stall, when a frame sent before t_r − rtt is still being retransmitted;
  - D_rate, the D of the newest `RATE` among frames ≤ H.
- **Per player** (in `Lync.perceived`): heldRaw = t_r − t_s − rtt, how long the client had held frame s when it
  sent; hMax = (send time of the next state frame to p after s, or t_r if none) − t_s + 1/60 s; held =
  clamp(heldRaw, 0, hMax); **Q = T_s + held × `stateRate`**, the newest state the client had applied; **R** = the
  state tick of the flush that sent reliable frame H, where reliable fields are returned.
- **Per collection** (in each `rewound` result), with D = the collection's `delay` option, else D_rate:
  - **P = Q − D × `stateRate`**, the tick the client was rendering, where `:newest()` fields are returned;
  - window: lowTick = max(P − u, T_s − D × rate), highTick = min(P + u, T_s + (hMax − D) × rate), u = (jitter + 1/60 s) ×
    `stateRate`: the arrival jitter of τ* plus §11.2's one-flush dead band.
- **The clamp is on Lync's own estimate**, not on anything the client sent: s pins the frame, and held places the
  send between frame s and the next one the server sent. `heldRaw` and `hMax` are returned, so a game sees when it
  bit (§12.9).

### 12.4 Decision: truth at P, or what the viewer had

- **Problem.** Under the budget a viewer doesn't get every row (the 100-player shooter's rows run at about 13 Hz
  instead of 20, §5), and rows are lost. The client samples what it *received*; the truth ring holds every tick.
- **Measured** (`interest-rewind/rewind_full.out`: a target strafing at 16 studs/s, reversing every 0.2–0.6 s, 20 Hz,
  D = 2 ticks; error of truth-at-P against the client's own samples):

| Rows missing | Mean | p99 | Max |
|---|---|---|---|
| 0% | 0 | 0 | 0 |
| 5% (loss) | 0.005 studs | 0.16 | 1.24 |
| 33% (≈ the 100-player shooter's deferral) | 0.084 | 1.33 | 4.89 |
| 50% | 0.245 | 2.55 | 8.66 |

- **Options:** `"truth"`, §11.2's sampling of the truth ring at P with every tick available; `"received"`, the same
  sampling over only the samples this viewer had (its per-pair bits, values read from the truth ring). The inputs
  are the client's: its samples are every row of the occupant that arrived plus its add (§11.2), the ack reports
  every arrival, and the add's sample is the ring's slot at A (§2, §12.2). A modified client can clear `received`
  bits to choose which samples bracket P; the bracket is returned (§12.5) and `"truth"` is unaffected (§12.9).
- **Choice: `"received"` by default; `"truth"` stays for games that want no per-pair memory.** With interpolation in
  the core, the sampling a viewer saw is always §11.2's, so draft 3.5's dependence of the default on an extension is
  gone. A game with its own interpolation also samples what it received, so `"received"` with its `delay` is the
  closer of the two for it too.

### 12.5 API

```luau
Net.strike:connect(function(player, shot)
	local seen = Lync.perceived(player)
	local target = Net.fighters:rewound(seen, shot.target)
	if target.ok then
		-- game code: its own ray test against target.value.position, with its own tolerance;
		-- target.tick, target.fromTick and target.toTick say where and between which samples it was taken
	end
end)
```

- **`Lync.perceived(player)`** returns a frozen value of the frame's and the player's inputs only: `ackSeq`,
  `ackTick` (T_s), `ackExact` (f carried a full ack), `received` (H), `receivedExact`, `reliableTick` (R),
  `applied` (Q), `held`, `heldRaw`, `hMax`, `ping`, `ackRtt`, `rtt`, `jitter`, `rateDelay` (D_rate, s), `arrival`
  (t_r). None depends on a collection, so one value serves every collection and §12.7's parts; each collection
  derives its own P and window from it. It may be stored and used while its ticks stay in the rings; computed once
  per frame, 26–32 ns native.
- **Decision: where `perceived` may be called** (shared with `v5-checks.md`).
  - *Problem.* Lync knows which frame a message came from only while it runs game code for that message. Checks
    (`within` references, `derive`'s `fn`) and validators run at steps 5 and 6 of `v5.md` §6.1, before the handler,
    and a check of a claim against rewound state needs the perceived tick there.
  - *Options:* the handler's synchronous part only (checks can't use rewound references); pass `seen` as an
    argument to check functions (a second way to obtain one value); **every synchronous call Lync makes for the
    message**.
  - *Choice: every synchronous call for the message.* `Lync.perceived(player)` works inside check functions, the
    validator and the handler's synchronous part (before its first yield) of a message from `player`; the value is
    the same in each, since the frame is. Anywhere else, or for another player, it throws the caller error
    `perceivedOutsideDispatch`.
- **`Net.c:rewound(seen, key)`** returns `{ ok: true, value, tick, lowTick, highTick, delay, fromTick, toTick }`: the
  declared fields (`:newest()` fields at P by `mode`, reliable fields at R), this collection's P, window and D (s),
  and the two sample ticks the value was taken between (equal when it was held or extrapolated from one). Or
  `{ ok: false, error }`, the one error model of `v5.md` §3.5:
  - `"expired"`: P or R is older than the ring, or the frame had no ack;
  - `"notHeld"`: the record existed but the viewer didn't hold it at H (no add counted ≤ H without a later remove
    ≤ H), or in `"received"` mode had no sample of it in the ring. On an unmodified client: the game also shows the
    entity through Workspace or another remote, or H was estimated (`receivedExact` false) during a reliable-lane
    stall;
  - `"unknownKey"`: no record with that key in the ring and no decoy of this player (§12.6).
- **`Net.c:rewoundSpan(seen, key)`** returns the records at the window's ends, as `{ ok: true, value: { low, high },
  tick, lowTick, highTick, delay }` or the same errors. **`Net.c:at(tick, key)`** reads the truth ring at a fractional tick, with no viewer.
  **`Net.c:held(seen)`** returns a frozen array of every key for which `rewound(seen, key)` is ok, in slot order, so a
  ray-only shot can iterate what the client held `[decoy-challenge-facts §1]`.

### 12.6 Decoys under rewind

When a collection has both decoys and `rewind` `[decoy-challenge-facts §1]`:
- each live decoy's declared fields go into a ring of its own each state tick: the same slot layout and K, holding
  the values its viewer was sent;
- `rewound(seen, key)` for a decoy of `seen`'s player returns its values from that ring, with the result shape of a
  real record; `"received"` mode works unchanged, since decoy rows are rows of that viewer's state frames. A tick
  outside the decoy's life (its history in `v5-integrity.md` §8, kept max(2 s, `maxRewind` + 0.25 s) after its
  remove) gives `"notHeld"`; another viewer's decoy gives `"unknownKey"`, as a never-live key does, since that player
  was never sent it; `at(tick, key)` gives `"unknownKey"` for every decoy: a decoy has no truth, only what one viewer
  was shown;
- `held(seen)` includes the viewer's decoys alive in the window; decoy slots come from the one allocator (§2), so
  decoys fall among real records in slot order;
- no decoy flag on results and no fact from `rewound`: the game's hit test runs as for any record, and a hit it
  finds is stated through `reportInteraction` (`v5-integrity.md` §8).
- Cost: 9.5–10.5 ns per decoy per state tick; `maxPerViewer` × K × 24 B per viewer with decoys (65 KB at 100
  viewers, 1 decoy, 20 Hz, 1 s); `held` 316–564 ns native per call at 65 keys, 808–891 ns at 301
  `[decoy-challenge-facts §4.3]`.

### 12.7 Engine parts

Characters the game doesn't render from Lync records are replicated by the engine with an interpolation delay no
property reports; Roblox replaced that backend in 2026 (`ImprovedPhysicsReplication`) and published no figure, so the
delay is unverified and stays out of Lync's constants `[interest-rewind §11.4]`.

`local parts = Lync.rewindParts({ engineDelay, engineSpread, maxRewind })` (server) returns a tracker:
`parts:track(part)`, `parts:untrack(part)`, and `parts:rewound(seen, part)` returning `{ ok: true, value: { low:
CFrame, high: CFrame } }`, the part's `CFrame` at both ends of [t_r − rtt − `engineDelay` − `engineSpread`,
t_r − rtt − `engineDelay` + `engineSpread`], or `{ ok: false, error: "expired" | "unknownKey" }` (older than the
ring; a part not tracked then). The server's state reaches the client one downlink later and is drawn
`engineDelay` after that, and the message arrives one uplink after it was sent, so the client was showing the state
of t_r − rtt − `engineDelay`. Lync guarantees the span formula exactly and that a hit test against the swept span is
correct for any true client-side delay inside [`engineDelay` − `engineSpread`, `engineDelay` + `engineSpread`];
nothing about what the delay is.

| Option | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|
| `engineDelay` | number (real) | s | 0–0.5 | required: the engine's delay is unpublished and its backend was replaced in 2026, so the value comes from the game's own calibration (below) | none |
| `engineSpread` | number (real) | s | 0–0.25 | required, from the same calibration | none |
| `maxRewind` | number (real) | s | 0.1–2 | 1 (as §12.2) | per part, ⌈(`maxRewind` + `engineDelay` + `engineSpread`) × `stateRate`⌉ + 2 slots of 32 B (tick u32, position 3 × f32, rotation 4 × f32); one `CFrame` read per part per state tick, which allocates (unmeasured on Roblox) |

The docs give the calibration recipe: on a test server, the server keeps a ring of a character's root `CFrame` by
time, a test-only client reports the rendered `CFrame` of another character with its own time, and the
best-fitting lag, minus that client's one-way estimate (rtt/2 at the sample), gives the client-side delay; its median
and spread are the two options. Those reports are client-stated, for calibration only. Games that need exact rewind
of characters render them from Lync records `[anticheat-design §1.2]`.

### 12.8 Cost

`interest-rewind/rewind_full.out` and `rewind_cost.out`; native is the server figure.

| Operation | Native | Interpreted |
|---|---|---|
| push, one record per tick (24 B slot) | 9.5–10.5 ns | 130–138 ns |
| perceived tick (map lookup, clamps, window) | 26–32 ns | 130–134 ns |
| truth sample: lerp xyz, two rotation decodes, nlerp | 80–87 ns | 381–388 ns |
| received: record one acked row | 8.3–8.8 ns | 56 ns |
| received: bracket P, lerp, two decodes | 108–121 ns | 389–437 ns |

| Model (`maxRewind` 1 s) | K | Ring per record | Ring total | Seq map | Received (⌈K / 8⌉ B per pair, derived) |
|---|---|---|---|---|---|
| shooter, 30 players, 20 Hz | 27 | 648 B | 19 KB | 9.7 KB | 3.6 KB |
| shooter, 30 players, 60 Hz | 77 | 1,848 B | 55 KB | 28 KB | 9 KB |
| shooter, 100 players, 20 Hz | 27 | 648 B | 65 KB | 32 KB | 40 KB |
| mmo, 300 tracked, 100 viewers, 20 Hz | 27 | 648 B | 194 KB | 32 KB | 120 KB |

At the 100-player shooter (about 66 rows per viewer per tick under the 16,000 B/s budget; 10 claims a second per
player, 5 targets each): pushes 21 µs/s, received recording 1.2 ms/s, queries 0.64 ms/s, about 1.8 ms/s in total,
0.2% of a core (derived from the tables). The reliable-frame map and the per-pair add/remove counts are not in the
probe: at most 60 reliable frames a second × 1.25 s × 16 B = 1.2 KB per player, and two u32 per membership change
held for max(2 s, `maxRewind` + 0.25 s) (derived). Wire: 28 bits per `perceived` frame that would have carried `'0'`.

### 12.9 How it fails on an unmodified client

- **Ping above `maxRewind` − D:** `"expired"`. The game chooses whether to judge at the oldest tick or refuse;
  under-coverage punishes high-ping players with misses `[anticheat-design §4.1]`.
- **Bursty downstream loss, or a client hitch longer than a tick:** the client held s past the next frame the server
  sent, so `heldRaw` > `hMax`, held is clamped, and P is older than the client's by up to the excess.
- **Round-trip error:** held, Q, the estimated horizon and the engine-part span move by the error in rtt (engine
  ping raised to Lync's ack round trip by at most `rewind.rttSlack`). Link asymmetry doesn't enter: each uses the
  whole round trip.
- **Reliable fields** are returned at R, the tick of the newest reliable frame the client had decoded; values written
  in later non-state-tick flushes of that tick are newer than the ring's slot, an error of under one state tick. For
  messages of undeclared definitions on the unreliable lane H is estimated (`receivedExact` false) and is too new
  during a reliable-lane stall: R, D and membership can then come from frames the client hadn't decoded.
- **Clock slew:** τ deviates from τ* by up to one client flush in steady state, and after a jump in τ* converges at
  4% (§11.2); the window's u covers the first, not a large recent jump.
- **A game's own interpolation** with a delay other than `delay`: P is off by the difference.
- **Defeated by** (capability class): a modified client that delays its own traffic, engine pings included, or
  acks an older state frame than it holds, moves P older, at most to `maxRewind`: the inherent limit of lag
  compensation, which Bernier accepts. `held`, `heldRaw`, `hMax`, `ping`, `rtt` and `ackTick` show it as numbers.
  One that clears `received` bits widens the `"received"` bracket around P to samples it chooses, within the window;
  `fromTick` and `toTick` show the bracket, and `"truth"` is unaffected. Lync attaches no verdict. Aim is an input,
  and an aimbot passes any geometric test.

## 13. Withholding content: engine streaming and staged namespaces

### 13.1 What engine streaming shows

The docs carry a page, "What engine streaming shows, and what Lync can hide" `[interest-rewind §12.1–§12.2]`:
- **The leak radius of an entity is the larger of the engine's and Lync's.** Interest hides a record beyond its
  cells only if the same information isn't in Workspace too: a part, a model, an attribute, a character.
- **The engine's region is wider than `StreamingTargetRadius`:** under the default `StreamOutBehavior` `LowMemory` a
  client streams out only in a low-memory situation, frustum streaming and predictive foci widen it, and extra foci
  add to it (documented). Treat it as everything the client has been near since joining. A smaller radius,
  `StreamOutBehavior = Opportunistic`, `ModelStreamingBehavior = Improved` and no frustum streaming reduce it; none
  hides anything from a modified client inside it.
- **Never put a secret in a Workspace attribute or value**, or in `ReplicatedStorage`: they reach every client at
  join, whatever the radius.
- **Fog of war for players** needs characters rendered from Lync records; interest and rewind then work on exact
  data.
- Lync's interest focus defaults to the engine's (§8.3). The streaming properties are `NotScriptable` (API dump
  0.741.19), so only the build reads them, into `report.md` (`v5-tooling.md` §1).

### 13.2 Staged namespaces

- **What leaks.** Anything replicated can be read before it is used: models in `ReplicatedStorage`, any replicated
  script's code (documented: clients can "decompile any replicated LocalScript or any ModuleScript"), and Lync's
  shared schema and client shard, which name every definition, field and enum item. Kicking doesn't help:
  replication begins before server kick logic can run (documented) `[interest-rewind §12.3]`.
- **Mechanism.** A namespace declared `[[namespace]] staged = true` in `lync.toml` has its schema module and client
  shard built under `ServerStorage` (`v5-tooling.md` §2). At release, server code calls `Lync.release(view, folder)`:
  - `view` is the staged namespace's server view; the call is its first server-side use if nothing used it before,
    so the server assigns its index (`v5.md` §4.6);
  - then `folder`, the `Folder` holding its schema module and client shard, is parented to `ReplicatedStorage`;
  - client code waits for the folder (by the path `[[staged]] loader` names) and requires the client shard, which
    sends `HELLO` and gets `WELCOME`. No restart, no new remote; released namespaces and their hashes are unchanged.
  - A `folder` that is not a `Folder` under `ServerStorage` (a second call included) throws the caller error
    `releaseTarget`; a client view as `view` throws `wrongSide` (`v5.md` §3.5). A server view already in use is
    accepted: the call then only replicates the folder. Requiring the view first keeps every client `HELLO` inside the server's 10 s wait.
- **Cost.** One namespace index more in the segment toc: EG-0 of index i is 2⌊log2(i + 1)⌋ + 1 bits per segment of
  that namespace (3 bits for 1–2, 5 for 3–6); one `HELLO`/`WELCOME` round trip per client at release, with sends
  meanwhile in the join hold (32,768 B, `v5.md` §5.3); one more schema module per staged feature.
- **Limit.** Content that extends a *released* definition (a new item in a released enum) can't be staged: it needs
  a new build and a restart.
- **Build checks** `stagedReplicated`, `stagedReferenced` (both `"error"`), `stagedNameLeak` and `streamingOff` are
  in `v5-tooling.md` §3. No build can check an asset it isn't told is unreleased, game code parenting content into a
  replicated container early, or attributes set at run time.

## 14. Codes, counters and constants

**Codes raised here** (registered in `v5.md` §7.1; names provisional until the naming pass):

| Code | Family | Trigger |
|---|---|---|
| `visibilityPlacement` | declaration | a visibility modifier off a top-level reliable field of a collection record, on a `:newest()` field, or a second modifier on one field (§9) |
| `fieldCodec` | caller (as `unknownField`, which server-view declarations already throw) | on the untyped path, a server-view option names a field whose codec the option doesn't take: `interest` `position`, `about`, `rewind` `fields` (§8.2, §10, §12.2) |
| `perceivedOutsideDispatch` | caller | `Lync.perceived(player)` outside a synchronous call for a message from `player` (§12.5) |
| `releaseTarget` | caller | `Lync.release` with a `folder` that is not a `Folder` under `ServerStorage` (§13.2) |
| `decoyOutsideInterest` | caller (behaviour channel, as `decoyKeyLive`) | a decoy failing §8.6's test |
| `focusError`, `focusYielded` | fault | an interest `focus` call throws, or yields (§8.7) |
| `predicateError`, `predicateYielded` | fault | an interest predicate throws, or yields (§8.7) |
| `weightError`, `weightYielded` | fault | a `weight` call throws, returns a value outside (0, 1000] or not a finite number, or yields (§7, §8.7) |
| `bindingError`, `bindingYielded` | fault | an `owner`, `team` or `gate` binding throws, or yields (§8.7, §9) |
| `ownerUnbound`, `teamUnbound`, `gateUnbound` | fault | a class modifier with no binding at the first state tick with a record (§9) |

Option errors reuse `unknownOption`, `missingOption`, `paramRange` and `unknownField`. No fact is added: interest,
classes and scoping are the server's own behaviour, and rewind can't know a message is a claim.

**Counters** (`Lync.counters`, `v5.md` §7.4; `<field>.<namespace>.<collection>`, and per viewer with `player`). The
last column states what the count equals; causes go on the registry pages:

| Counter | Increments by | Equals |
|---|---|---|
| `relevantPairTicks` | the viewer's member count, once per viewer per state tick | ÷ (viewers × ticks): the mean number of members per viewer |
| `interestEnters`, `interestLeaves` | each catch-up add, and each remove, caused by interest | adds and removes caused by interest; ÷ (viewers × seconds) per viewer per second |
| `narrowedPairs` | each pair the cells admitted and `pvs` or `predicate` removed | pairs withheld by the table or the predicate |
| `predicateErrors` | each predicate throw or yield | predicate calls that gave `predicateOnError`'s result |
| `scopedDropped` (`.<namespace>.<definition>`) | each (message, viewer) a scoped event skipped (§10) | scoped messages not sent |
| `decoysUnplaced` | each decoy add not made because `maxSlots` was reached or no slot was free (§2) | decoy adds deferred to a later tick |

Cost: one add per viewer per state tick and one per membership change, 0.1 ns per pair native and 0.2 interpreted
amortised over 160-member sets `[interest-rewind §9]`; a snapshot copies six more numbers per collection.

**Constants** (`v5.md` §4.9's rule: none is a knob):

| Protocol constant | Value | Derivation |
|---|---|---|
| generation | `gen:u2` in every add and row | §2 |
| segment | `seg:u1` in every add and row | §11.3 |
| state chunk kind | `kind:u1` | §3 |
| D unit, step | 4 ms, u8 in `RATE`; one unit per second | §11.1 |
| extrapolation cap | 0.25 s | chosen: Source's `cl_extrapolate_amount` `[state-sync §6.3]`, unmeasured here; both ends must hold it for rewind to reproduce sampling (§11.2) |

| Runtime constant | Value | Derivation |
|---|---|---|
| cell hysteresis | a member leaves when two cells away | chosen: ReplicationGraph-style ring `[state-sync §7.2]`, unmeasured here; bounds churn to one leave per two cells of travel |
| table hysteresis | the stay table, one table cell of viewer travel | §8.5 |
| order classes | 40, c = clamp(⌊log2 s⌋, −20, 19) | §7 |
| timing window | 5 s of ack round-trip samples | chosen, unmeasured (§11.1) |
| rendering clock | ±4% slew; dead band one client flush; snap above 0.25 s | chosen: Mirror's 2–4% `[state-sync §6.3]`, unmeasured here (§11.2) |
| rewind history | max(2 s, `maxRewind` + 0.25 s) | the slot reuse delay, or the window plus the extrapolation cap |

Developer options introduced here, beside the declarations' own tables: `state.maxPendingAge` (§7),
`interpolation.delayFloor` and `interpolation.jitterFactor` (§11.1), `rewind.rttSlack` (§12.3), all in
`Lync.configure` (`v5.md` §7.5).

## 15. Pending measurements

None blocks milestone 4; each has a default the design uses.
- The column-coding loss of reliable updates sent as pieces (hysteresis, predicates, owner fields) against cell
  chunks (§8.4), and of class fields coded against the previous row instead of their last sent value (§3).
- The cost of §8.7's callback thread (one `resume` per call) native and on a Roblox server; 119 ns interpreted on
  the CLI.
- The rate of pairs a bake marks hidden that are visible, on real maps (§8.5).
- `Player:GetNetworkPing()` per-call cost and smoothing on servers; the cost of reading `ReplicationFocus` or
  `PrimaryPart` per viewer per state tick, and of the `CFrame` read per tracked part (allocates).
- The engine's interpolation delay under `ImprovedPhysicsReplication` (`engineDelay`).
- `WorldRoot:Raycast` cost on a Roblox server (reported 10–17 µs per ray), for games that call it in a predicate.
- Whether a module returning a 170 KiB or larger base64 string is accepted (a 1,024-cell table), and the time of
  `EncodingService:Base64Decode` on it.
- `interpolated` on clients: CPU per call and garbage per second at 64 records × 60 Hz.
- Round-trip distribution of real players, which `lookAhead` and `maxRewind` would be set from.
