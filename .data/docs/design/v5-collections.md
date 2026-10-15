# Lync v5: collections (milestone 4)

Draft 3, 2026-10-15. Part of the v5 design (`v5.md`); this file specifies milestone 4. Wire terms (chunks,
segments, `align`, EG-k, column blocks, extended sequences) are defined in `v5.md` §4.

## 1. Model

A collection replicates keyed records (or one singleton record, with no `key`) from the server to clients. Each
case uses the model that won on the measured trade-off `[state-sync §1, Implications]`:

| What | Lane | When | Model |
|---|---|---|---|
| structure: add, remove, audience change | reliable | every flush | changes since the last flush, encoded once per audience partition |
| reliable fields | reliable | every flush, or at `reliableRate` | changes since the last send, encoded once per partition, no acks (ordered delivery keeps the client equal to the last sent state) |
| `:newest()` fields | unreliable | state ticks | absolute rows encoded once per tick, chosen per viewer, repaired by notify |

- **Reliable fields are sent as often as they are written** (every flush) unless the collection declares
  `reliableRate`: then field changes are coalesced and sent on flushes where ⌊(`GetServerTimeNow()` − epoch) ×
  `reliableRate`⌋ has advanced, while structure still goes every flush. With `reliableRate`, an event fired after a
  field write can arrive before that write; without it, the order is exact `[review-2 M5]`.
- **Not atomic across lanes.** A record with reliable and `:newest()` fields changes on two lanes, so `changed` can
  fire twice in one state tick. A collection that needs one change per tick declares no `:newest()` fields.
- **Unreliable means unreliable.** Unreliable *events* are never resent; only `:newest()` fields are repaired.

## 2. Records and slots

- **Slots.** A collection has `maxRecords` slots, ws = ⌈log2 maxRecords⌉ bits (0 for a singleton). A slot freed by
  a remove becomes reusable 2 s later, so `maxRecords` must cover live records plus those removed in the last 2 s.
  A `set` that finds no free slot throws `recordLimit` at the caller `[review-2 m4]`. Slots are drawn uniformly
  at random among free slots (server `Random`), which `v5-integrity.md` relies on for decoys.
- **Keys** travel once, in the add; everything after addresses the record by slot.
- **Generations.** Both ends count adds per slot modulo 4 (the reliable lane is ordered, so they agree). Only
  unreliable rows carry the 2-bit generation, because only they can arrive before their add or after their remove
  `[review-redundancy-2 11]`. A client holds at most one early row per slot whose generation it hasn't added yet,
  applies it on the add, and drops rows of older generations.
- **Reads are copy-on-write.** Each change builds the next frozen record once; `get` returns it without copying
  (7 ns against 166 ns and 320 B for clone-on-read, interpreted), and `changed` passes the previous frozen record as
  `previous` for nothing. The cost moves to applying changes: 182 ns and 320 B per changed record, interpreted
  (64 fighters at 20 Hz ≈ 0.23 ms/s and 410 KB/s of garbage) `[probes review-redundancy get_snapshot]`
  `[review-redundancy-2 R18]`.
- **Server API.** `set(key, record)` adds or replaces; `patch(key, partial)` changes fields (a misspelled key is
  `unknownPatchKey`); `remove(key)`; `audience(key, target)`. A singleton's take no key.
- **Client API.** `get(key)`; signals `added(key, record)`, `changed(key, record, previous)`, `removed(key)`.

## 3. Chunks

```
state chunk  := collection:u(wc) adds updates
adds         := n:EG0, then n rows of { slot:u(ws) key fields }               -- every field, :newest() included
updates      := n:EG0, then n rows of { slot:u(ws) mask fields }              -- mask: 1 bit per reliable field; then the masked fields
remove chunk := collection:u(wc) n−1:EG0, then n × slot:u(ws)
rows chunk   := collection:u(wc) n−1:EG0, then n rows of { slot:u(ws) gen:u2 :newest() fields }  -- state frames only
```

- wc = ⌈log2(collections in the namespace)⌉; collection indices are the namespace's collection id space, permuted
  like the others (`v5.md` §4.5).
- **Column coding** applies to adds and updates of `columnMinRows` or more rows (`v5.md` §4.3). Add columns use the
  previous row as baseline; update columns use, per record, the value last sent to the partition (sound on the
  ordered lane). A mask column flattens like an optional: each field's column covers the rows whose mask has it.
  Slot columns are coded like any integer column. Rows chunks are never column-coded (§5).
- **Order inside a namespace's state chunks:** collections in index order; for each, a viewer's own catch-up chunk
  (§4) comes before the partition's shared chunk.

## 4. Audiences and catch-up

- Each record has an audience `Target`, `Lync.all` by default. Records with the same target value share a
  partition, encoded once for all its members. Group changes apply at the next flush.
- **Catch-up.** A viewer gaining sight of a record (`WELCOME`, an audience change) receives an add with every field
  in its own state chunk; losing sight is a remove. The catch-up add carries the partition's baseline (the values
  last sent to the partition) and precedes the partition's shared chunk in the same frame, so the shared update
  applies on top of it.
- **No audience-by-field shortcut.** A team-partitioned game keeps one group per team; the encoding is shared
  exactly as a field partition would be.
- **`interest`** (extension) refines an audience per viewer and never widens it.

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
- **Choice: absolute rows, encoded once per tick, as byte-aligned chunks copied per viewer.** Fast ranks above
  small: no history, no desynchronisation. Copying a 12 B row costs 27.6 ns native per viewer-row against 41.1 ns to
  bit-pack it per viewer `[probes review-redundancy-2 newest_rows]`; the padding costs 5.4–8% of bytes. A 100-player
  shooter's 1190 B per tick is 1.5x the default budget, so records update at about 13 Hz instead of 20. Acked
  prediction is the `acked` extension (2.3–2.8x fewer bytes on the shooters).
- **Wire.** Each record's row is encoded once per tick into its own byte-aligned piece (slot, generation, fields);
  a viewer's rows chunk is the header (`collection`, count) followed by copies of the selected pieces.

## 6. Repair (notify)

- Rows travel only in state frames, whose seq counts that viewer's state frames (`v5.md` §4.4). Per viewer, a ring
  of the last 17 state frames records which rows each carried, in a buffer (the ack covers 17 seqs). A frame is lost when an ack shows a newer seq received and not it; its rows
  become pending again unless a later frame carried them. A frame that leaves the ring unacked counts as lost.
- The client applies a record's row only if its frame's seq is newer than the stored one; both are extended
  sequences (`v5.md` §4.4), so a record idle for any time is never frozen `[review-redundancy-2 1]`.
- Reordering can cause a spurious resend, never a stale value.

## 7. Scheduling and budget

- **Budget.** At each state tick the scheduler may write up to `state.budget` × Δt − charged bytes of rows to a
  player, never less than `state.floor` × `state.budget` × Δt. Δt is the time since the previous state tick (at
  most 2/`state.rate`); charged is every byte sent to that player since (reliable frames, unreliable events).
- **Selection.** Per viewer, pending records wait in one FIFO per collection, ordered by the tick they became
  pending. The scheduler repeatedly takes the head with the largest `priority` × age (in state ticks) until the
  next row doesn't fit; a collection's rows are fixed-width, so then none of it fits and the others continue. A
  record re-pended after a loss is appended with its age restarting, which keeps each FIFO exact and O(1)
  `[review-redundancy-2 12]`. This costs 1.2–5.8x less than per-tick accumulators with a 40-bucket pass
  `[probes review-redundancy sched_fifo]`.
- **Over budget** Lync defers rows (counter `rowsDeferred`) and never lowers precision. Pending is a flag, so the
  backlog is bounded by the record count `[state-sync §3.9]`.
- Distance, owner and first-send boosts and per-field rate caps need per-viewer weights that change each tick: the
  `interest` extension.
