# Lync v5: `acked` and `inputs`, designed

Researcher brief, 2026-10-15. Settles every open value of `design/v5-extensions.md` (draft 3.6) for its two
remaining extensions. Read in full first: that file, `research/state-sync.md`, `research/compression.md`,
`design/v5.md` (§4, §5, §6.1, §7.5), `design/v5-collections.md`, `design/v5-checks.md` (§1, §3, §6, §7.1),
`research/interest-rewind.md` §11, `probes/inbound-budgets/RESULTS.md`.

Labels: **verified** (ran it or read the source), **documented** (vendor docs), **reported** (third party),
**unverified**. Probes are in `.data/docs/probes/acked-inputs/`. Luau figures: Luau 0.742 built from
`.data/projects/luau` (Release), `luau -O2` interpreted (the client) and `-O2 --codegen` native (the server),
on the shared 2.1 GHz Xeon (run-to-run spread about ±25%). Python sims: `python3 -I`, Python 3.13.16, numpy 2.5.3.

| Probe | What it answers |
|---|---|
| `acked_sim.py` (+ `acked_sim.{main,hist,loss,nobudget}.out`) | `acked` vs the core's pieces on the six model cases: B/s, rows applied per second, staleness, predictor, history length, ack timing, loss, scheduler bound |
| `acked_cost.luau` (+ `.out`) | server per-viewer encode (prediction, full mode and k search, writes) vs the core's copy; client decode and rebuild |
| `inputs_sim.py` (+ `.out`) | stream redundancy schemes vs playout depth on Lync's rates and network model |
| `inputs_cost.luau` (+ `.out`) | server parse cost per redundant copy |
| `core_uncapped.py` (+ `.out`) | the core's row bytes with no budget and no frame cap, where `acked_sim.py`'s one frame per tick caps it |

## Checklist

- [x] 1. `acked`: mechanism in Lync's terms
- [x] 2. `acked`: what it saves and what it costs, measured
- [x] 3. `acked`: encode-once, `FireAllClients`, budgets, interest, rewind, decoys
- [x] 4. `acked`: unmodified clients, refusals, the open values, options
- [x] 5. `inputs`: mechanism in Lync's terms
- [x] 6. `inputs`: what it saves and what it costs, measured
- [x] 7. `inputs`: budgets, checks, interest, rewind, Server Authority
- [x] 8. `inputs`: facts, unmodified clients, the open values, options
- [x] 9. Implications

## 1. `acked`: the mechanism in Lync's terms

### 1.1 Declaration

- `Lync.collection({ …, acked = true })` in the shared schema. The client must predict exactly as the server does,
  so it is hashed (`v5.md` §4.7): a boolean option after `sealed` in the option order, present with `false` when
  omitted, as `perceived` is. It applies to every `:newest()` field of that collection; nothing else changes.
- No other option. The history length, the predictor and its guard are protocol constants (§4.3), derived below.

### 1.2 Server state

- **Shared history** (once per collection, not per viewer): for each slot, the codes of every `:newest()` leaf at
  each of the last H = 32 state ticks, plus its `seg` bit, written once per tick from the same values every row of
  that tick carries (the values are the ones the core's piece encode reads, so this replaces the piece encode).
  A decoy's slot is written the same way, with the values its one viewer is sent.
- **Per (viewer, record)**: the ticks of the three newest acked rows of the record's current occupancy for that
  viewer (u32 each), and the tick of the viewer's latest catch-up add (u32): 16 B.
- **Per viewer**: the notify ring of 17 state frames already records which rows each frame carried and the frame's
  tick (`v5-collections.md` §6); `acked` reads it, it adds nothing to it.
- **On an ack** (the `ack` field of `v5.md` §4.1): for each frame the ack shows received, each row it carried
  whose tick is at or after the pair's add tick is inserted into the pair's newest-three list. Frames shown lost are
  re-pended exactly as in the core. A catch-up add (`WELCOME`, audience gain, interest entry) clears the pair's list.

### 1.3 Which baselines a row uses, and the prediction

For a row of record r at tick T to viewer v, the usable baselines are the pair's acked ticks t with T − t ≤ H − 1
whose history entry has the row's `seg` (a cut ends prediction across it, `v5-collections.md` §11.3):
- three usable and the collection has at least one linear leaf (below): **nb = 3**, baselines b0, b1, b2 at
  t0 > t1 > t2, ages a0 = T − t0, a1 = t0 − t1, a2 = t1 − t2 (each ≥ 1, a0 + a1 + a2 ≤ H − 1);
- otherwise one or more usable: **nb = 1**, b0 at the newest;
- none: **nb = 0**, prediction 0 for every leaf (the row is absolute codes).

Per leaf, on the leaf's code interval of n codes (`v5.md` §4.3's integer column codes):
- **Linear leaves** (guarded linear prediction, Unity's `GhostDeltaPredictor`, read in
  [`GhostDeltaPredictor.cs`](https://raw.githubusercontent.com/needle-mirror/com.unity.netcode/master/Runtime/Snapshot/GhostDeltaPredictor.cs)
  of the `needle-mirror/com.unity.netcode` mirror, fetched 2026-10-15: `predictFrac = 16 * baseline0_tick.TicksSince(baseline1_tick) / baseline1_tick.TicksSince(baseline2_tick)`,
  `applyFrac = 16 * tick.TicksSince(baseline0_tick) / baseline0_tick.TicksSince(baseline1_tick)`): `t.number`, `t.angle`, the three columns of
  `t.vector3` and of a `t.cframe`'s position, each with n ≤ 2^43; and `t.rotation`'s three component columns when
  the row and all three baselines have flag 0 and the same dropped index. With nb = 3, all arithmetic exact in
  doubles:
  - pf = ⌊16 · a1 / a2⌋, af = ⌊16 · a0 / a1⌋ (both ≤ 16 · 29 = 464);
  - d12 = wrap(b1 − b2), d01 = wrap(b0 − b1), where wrap takes a difference into [−⌊n/2⌋, ⌈n/2⌉ − 1];
  - pb = b1 + trunc(d12 · pf / 16); if |wrap(b0 − pb)| ≥ |d01| the prediction is b0, else
    (b0 + trunc(d01 · af / 16)) mod n. trunc rounds toward zero, as C#'s integer division in Unity's source.
  - Exactness: |d| < 2^42 and the fractions ≤ 464 < 2^9 keep every product below 2^51, hence the n ≤ 2^43 limit;
    a wider leaf is predicted as a non-linear one (derived, no option).
- **Every other leaf** (integers, enums, bools, instances' indices, rotation flags and indices, and linear leaves
  when nb = 1): the prediction is b0's code. `t.f32`, `t.f64`, `t.vector3f32` and `t.custom` stay raw columns, as in
  the core's column coder; they get no prediction.
- **A collection with no linear leaf** never uses nb = 3 (it would pay for ages that change nothing): derived from
  the schema on both ends.

### 1.4 Wire: the acked rows chunk

The core's rows chunk (`v5-collections.md` §3) is `collection n−1:EG0 align` then copies of byte-aligned pieces.
For an acked collection the same chunk position holds one column block per state frame:

```
acked rows chunk := collection:u(wc) n−1:EG0
                    refNb:u2 [ refA0−1:EG0 [ refA1−1:EG0 refA2−1:EG0 ] ]   -- the block's reference baselines
                    columns over the n rows, in slot order:
                      slot                     -- integer column, residual vs previous row (gaps)
                      own                      -- bool: 1 when the row's baselines differ from the reference
                      nb, a0−1, a1−1, a2−1     -- over own rows only (a0 when nb ≥ 1, a1 and a2 when nb = 3),
                                                  coded as values (baseline 0 per row, not the previous row)
                      gen, seg                 -- over rows with nb = 0 only
                      one column per leaf      -- zigzag(wrap(code − prediction)); bools: code XOR prediction
                    align
```

- Columns use the core's four modes unchanged (`v5.md` §4.3: zero, EG-k with `k:u4`, sparse, frame of reference),
  with the reference encoder's full search. A column over zero rows writes nothing.
- **The reference triple** is the baselines of the first row the scheduler admitted (the highest score); rows
  sharing it cost at most 1 bit each in `own` (EG-0 of a zero residual), and nothing when the whole column is zero.
  Measured: 94–100% of rows use three baselines (§2.1); the share sharing the reference is not separately counted.
- **`gen` and `seg` are implied for nb ≥ 1**: they are those of b0, since the server names baselines of the same
  occupancy and segment only. The client finds b0 by tick: one viewer receives at most one row per record per tick,
  and two occupants of one slot are at least the 2 s reuse delay apart, so a tick within H names one occupant.
- **The bound the scheduler uses** (exact, upper): rows are admitted in score order while the bound of the block
  so far fits the frame and the tick's budget. Per leaf column the bound is the smaller of mode 1's bits at the k
  that column chose in the viewer's previous block, and mode 2's at the same k with its gap bits bounded by
  m(2·log2(n/m) + 1) (Jensen's inequality on EG-0 of m gaps summing to at most n − m); the slot column is bounded by
  n(2·log2(2^(ws+1)/n + 1) + 1); `own`, `gen` and `seg` by their EG-0 worst case per row. The reference encoder
  picks the fewest bits over all modes and k, which includes each option the bound costs, so the block never
  exceeds it (asserted on every block of every run in `acked_sim.py`). Rows stop at the first that doesn't fit,
  the core's rule.

### 1.5 Client state and decode

- **Per record (slot occupant)**: the received rows' codes by tick, for ticks later than (the tick of the record's
  newest applied row) − H. Every row that can still apply has a tick at least that of the applied row and names
  baselines later than its own tick − H, so nothing the client drops can be named (derived). At most H entries.
  Rows that arrive before their add are kept the same way under their (slot, gen); on the add they join the store
  when their gen matches and T ≥ A (`v5-collections.md` §2's acceptance).
- **A late row** (an older seq than the applied one for that record) is parsed (the block must be walked) but not
  rebuilt or applied unless it is newer for its record; its codes, once rebuilt, are stored, since the server may
  name it.
- **The ack** of an acked collection's client covers only state frames it decoded and accepted. Acking a refused
  frame would let the server name rows the client never stored.
- **Decode rule** (client, a new canonical rule beside `v5.md` §4.8's): a row that acceptance would apply naming a
  baseline tick the client doesn't hold, ages outside 1 … H − 1 or summing past H − 1, nb = 2 (unused), or nb = 3 in a
  collection with no linear leaf, refuses the frame. Only a server bug produces it; it is counted in `refusedFrames`.

### 1.6 Loss, reordering, rekey, join, respawn

- **Loss downstream:** the lost frame's rows re-pend (core notify); the pair's baselines don't advance; nothing
  desynchronises, because only acked rows are ever named.
- **Loss upstream (acks):** each ack covers 17 seqs; a frame leaving the ring unacked is lost (core rule) and its
  rows are not baselines. Baselines age; once older than H − 1 they are unusable and rows fall back to nb = 1 or 0.
- **Reordering:** a late frame's rows apply only when newer for their record (core rule); its named baselines are
  held by §1.5's rule. A spurious resend stays possible, never a wrong value.
- **Rekey** (`v5.md` §4.5): unreliable upstream frames tagged under the old key are dropped as `tagMismatch` for at
  most one round trip, with their acks: the same as upstream loss.
- **Join and catch-up:** the catch-up add carries absolute values on the reliable lane; the pair starts empty, so
  the first rows are nb = 0 until one is acked (one round trip). The add itself is never a baseline: an add can
  leave in a non-state-tick flush with values written after that tick's history entry, so its tick doesn't
  identify its values (an exact reason, not cost).
- **Respawn and teleport:** `cut(key)` flips `seg`; no baseline of the other segment is named, so the first row
  after a cut is nb = 0 and prediction never extrapolates across the jump.
- **`state.rate` change:** the history restarts with the rate (as rewind's rings do); pairs are cleared.

## 2. `acked`: what it saves and what it costs, measured

### 2.1 Bytes and update rate (`acked_sim.py`, verified by running)

One viewer, 60 s per case, `state.budget` 16,000 B/s, `v5.md` §9's network (0.05 s + U(0, 0.02) s each way, 5%
Bernoulli loss each way), busy client (acks at its next 1/60 s flush). Every model field is a `:newest()` field.
"Rows/s" is rows applied per record per second (the tick rate minus losses and deferral); "stale" is the mean of
T − (tick of the client's newest applied row) over ticks where the client's value differs from the truth.

| Case | core B/s (no cap) | core under budget: B/s, rows/s, stale | `acked` G: B/s, rows/s, stale | bytes saved |
|---|---|---|---|---|
| shooter, 30 players, 20 Hz | 7,074 | 7,074, 18.80, 2.057 | 3,004, 18.80, 2.057 | 2.35× |
| shooter, 30 players, 60 Hz | 21,173 | 15,476, **40.91**, 4.768 | 8,390, **56.11**, 4.466 | 2.52× |
| shooter, 100 players, 20 Hz | 23,940 | 15,947, **12.53**, 2.432 | 9,546, **18.76**, 2.059 | 2.51× |
| racing, 12 cars, 60 Hz | 15,476 | 15,476, 56.17, 4.464 | 10,474, 56.14, 4.465 | 1.48× |
| mmo, ≈70 visible of 400, 20 Hz | 7,393 | 7,393, 7.27, 2.055 | 2,510, 7.27, 2.055 | 2.95× |
| tycoon, ≈160 records, 10 Hz | 11,901 | 9,943, 5.69, 1.269 | 2,434 (nb ≤ 1, §1.3), 6.81, 1.043 | 4.89× |

"No cap" is `core_uncapped.py` (every changed row, every tick, any number of frames); the sim sends one state frame
per tick, so its core figures for the 100-player shooter and the tycoon are capped at 1000 B per tick. What it makes
possible: the 100-player shooter's rows run at 18.76 per second per record (20 Hz minus 5% loss) inside the
default budget, against the core's 12.53; the 60 Hz shooter at 56.11 against 40.91. The earlier 2.3–2.8x
(`design-2/newest_layout.out`: lossless, every record every tick, fixed baseline age, no naming bits) holds on the
shooters and is exceeded on the mmo and tycoon; racing gains least (1.48×), its 60 Hz high-speed motion leaving the
largest residuals at a 6–7-tick baseline age.

**Predictor** (same runs, B/s): guarded linear (G) / unguarded linear (L) / delta against b0 only (D):

| Case | G | L | D |
|---|---|---|---|
| shooter 20 Hz | 3,004 | 3,041 (+1.2%) | 3,296 (+9.7%) |
| shooter 60 Hz | 8,390 | 8,556 (+2.0%) | 9,430 (+12.4%) |
| shooter 100p | 9,546 | 9,669 (+1.3%) | 10,547 (+10.5%) |
| racing 60 Hz | 10,474 | 10,888 (+4.0%) | 11,143 (+6.4%) |
| mmo 20 Hz | 2,510 | 2,608 (+3.9%) | 2,790 (+11.2%) |
| tycoon 10 Hz (no linear leaf) | 2,600 | 2,599 | **2,434 (−6.4%)** |

So Unity's guard as written wins wherever a linear leaf exists, and three baselines lose where none does, which is
§1.3's rule.

**History length H** (G, B/s): at 60 Hz the round trip is 7–8 ticks, so H = 8 leaves no usable baseline (100%
nb = 0: the 60 Hz shooter's rows fall to 33.32 per second at 12,120 B/s, below the core's 40.91; racing to
46.62 at 13,213); H = 16 already equals
H = 32 on both 60 Hz cases. Idle-heavy collections keep gaining slowly: mmo 2,899 (H 8), 2,614 (16), 2,510 (32),
2,490 (64), 2,466 (255); tycoon 2,660, 2,619, 2,600, 2,596, 2,585.

**Ack timing:** an idle client (ack-only frames after 2 unacked frames or 100 ms, `v5.md` §4.1) costs +4.5%
(shooter 20 Hz 3,140), +1.6% (60 Hz), +4.5% (100p), +0.8% (racing), +3.9% (mmo), +5.7% (tycoon).

**Loss** (core / `acked`, B/s and rows/s): bursty 5% (mean burst 3): shooter 100p 15,947 at 12.50 / 9,686 at 18.71;
bursty 15%: 15,947 at 11.28 / 9,996 at 16.88; mmo 15%: 7,425 / 2,637. `acked`'s bytes rise 1.5–5% from 5%
Bernoulli to 15% bursty, because lost acks age the baselines; nb = 0 stays at 0–2% of rows.

**Scheduler bound** (§1.4): bound ÷ actual block bits = 1.25–1.27 on the shooters, 1.10 racing, 1.29 mmo, 1.57
tycoon. A bound at the core's piece width (2.23–4.02× actual) admits only as many rows as the core: shooter 100p
12.53 rows/s at 7,165 B/s, the bytes saved but none of the rate.

### 2.2 CPU (`acked_cost.luau`, verified by running; 99 rows × 12 leaves, shooter-like)

| Path | Native (server) | Interpreted (client) |
|---|---|---|
| core: copy 99 × 12 B pieces into a viewer's frame | 33.6–35.7 ns per row | 40.8–42.0 ns per row |
| `acked` encode per viewer: 3 history lookups, guarded prediction on 5 linear leaves, residuals, full mode and k search per column, writes | **1,182–1,220 ns per row** | 4,939–5,205 ns per row |
| `acked` client decode and rebuild (generic reader: modes, EG-k, prediction, store) | 1,610–1,795 ns per row | **3,746–4,049 ns per row** |

- Round trip verified bit for bit on every leaf; the block is 537 B against 1,193 B of pieces for the same 99 rows.
- The k search uses an exact closed form: with L = bit length of v and r the length of its top run of one bits,
  EG-k(v) = k + 1 for k ≥ L, else 2L − k − 1 + 2·[k ≥ L − r]; per column that is O(1) work per value plus a
  16-step fold, and gives the reference encoder's minimum (block bytes unchanged against the per-k loop).
- **At the 100-player shooter, all 99 rows to every viewer at 20 Hz:** `acked` 234–242 ms/s of server CPU per
  second (24% of one core), against 6.96–7.08 ms/s of copies for the core (34× more). At 30 players, 20 Hz:
  30 × 29 × 20 × 1.2 µs ≈ 21 ms/s (derived). A generated encoder with straight-line leaves would cut the generic
  probe's loop overhead by an unmeasured amount.
- **Client:** 99 rows at 20 Hz cost 7.5–8.0 ms/s interpreted on this core (0.8%); a low-end phone's multiplier is
  unmeasured (`compression.md` §3.2's 3–5× is unverified).

### 2.3 Memory

- **Server, shared:** H × slots × leaves codes. As f64: 32 × 99 × 12 × 8 B = 304 KB for the 100-player shooter
  (152 KB as u32 for leaves of ≤ 32 bits), plus 1 bit of `seg` per slot per tick.
- **Server, per (viewer, record):** 16 B: 158 KB at 100 viewers × 99 records.
- **Client, per record:** at most H rows of codes (12 × 8 B each: 3 KB per record, 304 KB for 99); in steady
  state the rows between the newest applied one and its baselines, about (round trip in ticks + 3) rows: about
  6 × 96 B = 576 B per record at 20 Hz (derived).
- **Wire upstream:** none; `acked` uses the core's acks unchanged.

## 3. `acked`: encode-once, `FireAllClients`, budgets, interest, rewind, decoys

### 3.1 Where per-viewer prediction breaks encode-once, exactly

- **Breaks:** the rows of the acked collection only. In the core each record's row is encoded once per tick into a
  piece and copied per viewer (`v5-collections.md` §5); under `acked` the piece encode is replaced by one history
  write per record per tick, and each viewer's block is encoded for that viewer: 1.18–1.22 µs per (viewer, row)
  native against a 34–36 ns copy (§2.2).
- **Unchanged:** state frames are already per player by construction (`v5.md` §4.4: per-player `seq`), so no frame
  leaves `FireAllClients` because of `acked`; unreliable event frames stay shareable; reliable frames, adds,
  updates, removes and catch-up are untouched (catch-up adds carry absolute `:newest()` values, as in the core);
  other collections in the same state frame keep their pieces. The downstream layout stays per build, so per-player
  variants change nothing (`v5-collections.md` §5).
- **What would recover sharing, and why it isn't specified:** two viewers whose selected rows and every row's
  baselines are identical get identical blocks, so a cache keyed by (row set, triples) could encode once per group.
  With per-viewer acks under loss the hit rate depends on the game's ack timing; it is unmeasured, needs no wire
  change, and stays an implementation choice.

### 3.2 Budgets

- **Downstream:** `acked` rows are scheduled against `state.budget` exactly as pieces are, with §1.4's exact bound in
  place of the fixed piece width; `state.floor` and the age floor are unchanged.
- **Inbound:** none of the five inbound buckets changes. `acked` reads the core's ack (29 bits on the first
  unreliable frame of a flush, `v5.md` §4.1); ack-only frames keep the core's trigger (2 unacked frames or
  100 ms). An idle client acking every state frame instead of every second one would save 0.8–5.7% downstream
  (§2.1: 136 B/s on the 20 Hz shooter) for 10 more ack-only frames a second of about 10 B each (21-bit header,
  29-bit ack, toc, 4 B tag: 100 B/s up, derived), using 10 of the 120 `inbound.unreliable.frames` a second; the
  net of 36 B/s doesn't pay for a second trigger rule, so the core's is kept.
- **Server CPU** is downstream work the server chooses to do, outside §7.5's inbound bound: no client can raise it
  beyond what the schema, `state.budget` and the viewer count already set (a client that never acks only moves its
  own rows to nb = 0).

### 3.3 Interest, visibility classes, decoys

- **Interest:** membership, cells, hysteresis and the bucket pass are unchanged; `acked` encodes the selected rows.
  Every interest entry is a catch-up add, which clears the pair, so churn costs one round trip of nb = 0 rows per
  entry (mmo: 2% of rows at nb = 0, §2.1). The core's rows under interest are already per-viewer pieces, so
  `acked` loses no cell-chunk sharing: rows were never in cell chunks (`v5-collections.md` §8.4).
- **Visibility classes** apply only to reliable fields (`v5-collections.md` §9), so they don't meet `acked`.
- **Decoys** (`v5-integrity.md` §8): a decoy's rows are rows of its viewer's state frames, predicted like any
  record's from the history entries of its slot, which hold the values that viewer was sent. A decoy is therefore
  coded exactly as a real record of the same motion; its bits carry no mark.

### 3.4 Rewind and interpolation

- **Interpolation** (`v5-collections.md` §11) is unchanged: the client's samples are applied rows with their frame
  ticks, whatever coded them.
- **Rewind** `"received"` mode records the ticks of rows the viewer acked (`M = ⌈D × stateRate⌉ + 2` per pair);
  `acked`'s newest-three acked ticks per pair are the same acks, so when both are declared the pair keeps
  max(M, 3) ticks once (derived). The truth ring (24 B slots, decoded values) and `acked`'s history (codes) stay two
  structures: rewind keeps decoded positions and rotation codes for `K = ⌈(maxRewind + 0.25) × stateRate⌉ + 2`
  ticks, `acked` keeps every `:newest()` leaf's code for 32.
- **Perceived tick:** unaffected; the frame's own ack names the state frame (`v5-collections.md` §12.3).

## 4. `acked`: unmodified clients, refusals, the open values, options

### 4.1 How it fails on an unmodified client, and what a modified one can do

- **No fact is added.** Every input to the coding is the server's own state or the client's acks; a client can't
  make the server do more than the core already allows. Codes added: the client decode rule of §1.5 (a frame
  refused under it is counted in `refusedFrames`, `v5.md` §7.4; known cause: a Lync bug only) and the declaration
  error below.
- **Unmodified-client effects, all byte or latency effects, none a wrong value:** a round trip above
  (H − 3) ticks (1.45 s at 20 Hz, 0.48 s at 60 Hz) leaves fewer than three usable baselines, so rows fall to
  nb = 1 or 0 and cost up to the core's bytes plus the naming bits; bursty loss ages baselines (+1.5–5%, §2.1);
  every catch-up add and every cut costs one round trip of nb = 0 rows.
- **A modified client** that acks frames it never received makes the server name rows it lacks: its own later
  frames are refused under §1.5's rule, so only its own view breaks. One that never acks gets nb = 0 rows: the
  core's information at slightly more bytes. Acks naming unsent seqs are already `impossibleAck`. None of this
  costs the server more than an unmodified client of the same viewer count.
- **Declaration error** `ackedNoNewest` (declaration family, `v5.md` §7.1): `acked = true` on a collection with no
  `:newest()` field, since the option would code nothing.

### 4.2 The open values of `v5-extensions.md`, settled

| Open value | Outcome | Evidence |
|---|---|---|
| where it is declared | the shared schema, `acked = true` on the collection, hashed after `sealed` | the client predicts with the same constants (§1.1) |
| history length | **H = 32 state ticks, a protocol constant.** Derived minimum: a row is acked within the 17-frame notify ring, and three baselines need two older ticks, so a record sent every tick needs 17 + 2 = 19; 32 is the next power of two, so `T mod H` is a mask (chosen) | H 16 = H 32 at 60 Hz, H 8 fails there; idle-heavy mmo gains 0.8% at 64 and 1.8% at 255 against 32 (§2.1); memory 304 KB per 100 × 12-leaf records at 32 |
| the predictor's guard | **Unity's guard as written**, tick-ratio fractions in 1/16, truncation toward zero; three baselines only in collections with a linear leaf | G beats L by 1.2–4.0% and D by 6.4–12.4%; D beats G by 6.4% on the tycoon, which has no linear leaf (§2.1) |
| per-viewer encode cost at 100 viewers | **1.18–1.22 µs per (viewer, row) native, 234–242 ms/s for the 100-player shooter's 99 rows to 100 viewers at 20 Hz** (24% of one core), against 7 ms/s of copies | `acked_cost.out` |
| (added) the scheduler's size bound | exact upper bound of §1.4; a piece-width bound is refused, because it removes the rate gain | bound ÷ actual 1.10–1.57, piece-width bound 2.23–4.02 (§2.1) |
| (added) baseline naming | a reference triple per block plus an `own` column; `gen` and `seg` implied by b0 | 94–100% of rows at nb = 3 (§2.1) |

Outcome: **adopt**, as specified in §1, for any collection with `:newest()` fields.

### 4.3 Options and constants

| Name | Where | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|---|
| `acked` | shared schema, collection | boolean | — | — | `false` | 1.18–1.22 µs native per (viewer, row) server encode, 3.7–4.0 µs interpreted per row client decode; 304 KB history and 16 B per (viewer, record) at the 100-player shooter; saves 1.48–4.89× of the collection's row bytes |

| Constant | Value | Derivation |
|---|---|---|
| history H | 32 state ticks | ≥ 17 (notify ring) + 2; next power of two, chosen |
| baseline counts | nb ∈ {0, 1, 3}; nb = 3 only with a linear leaf | Unity uses three or one: `FindBaselines` in [`GhostChunkSerializer.cs`](https://raw.githubusercontent.com/needle-mirror/com.unity.netcode/master/Runtime/Snapshot/GhostChunkSerializer.cs) marks baselines 1 and 2 unavailable together when the third is missing, and writes each run's three baseline ages with `WritePackedUInt` (fetched 2026-10-15, read through the fetch tool's extract, so reported); §2.1 |
| linear leaves | `t.number`, `t.angle`, `t.vector3` and `t.cframe` position columns, `t.rotation` components on equal layout; n ≤ 2^43 | exact products below 2^51 (§1.3) |
| fraction unit | 1/16, truncation toward zero | Unity's `GhostDeltaPredictor` |
| reference triple | the first admitted row's baselines | §1.4 |

## 5. `inputs`: the mechanism in Lync's terms

### 5.1 Why the upstream unreliable seq can't be the input index

`v5-extensions.md` names the upstream unreliable `seq` as the input index. It isn't one: `seq` counts a client's
unreliable frames (`v5.md` §4.4), a flush may send several (split at 1000 B) or none, and the flush accumulator runs
29.1 steps a second at 30 FPS (`v5.md` §5.1), so seq advances neither once per input nor at a fixed rate. Playout in
state ticks needs an index that is a tick. So **the index is the client's state tick**:
K = ⌊(`GetServerTimeNow()` − epoch) × `stateRate`⌋, the estimate the client already uses to extend `tick:u8`
(`v5.md` §4.1), one input per tick of `state.rate`.

### 5.2 Declaration and API

- **Shared schema:** `move = Lync.stream({ data = codec })`, a fourth definition kind (hash kind byte 4, `from`
  client, lane unreliable; `v5.md` §4.7), in the namespace's up id space. `data` must have a fixed single-row width
  (no strings, buffers, arrays, maps, optionals or unions; the rule of `rewind`'s `fields`), else the declaration
  error `streamCodec`: copies are delta-coded per top-level field, which needs fixed fields. The streams of a
  namespace must fit one chunk each at 33 copies in 960 B together (`streamTooLarge`), so they always ride the first
  unreliable frame of a flush, with one fate and one ack.
- **Client:** `Net.move:set(value)` latches the value; `Net.move:stop()` ends sampling until the next `set`.
- **Server view:** `Net.move:playout({ depth = J })` sets the depth for every player; `Net.move:playout({ depth = J,
  player = p })` for one. `Net.move:connect(function(player, input, index) … end)` throws the caller error
  `playoutUnset` while no depth is set: the depth is the developer's, and there is no default. Each change for a
  player sends that client a `DEPTH` control message (type 4, unused until now: definition id u(w), depth u5; 1–2 B
  with its chunk header).
- **Delivery:** each received index exactly once, in index order, at its playout time; a missing index is a jump in
  `index`, never a nil value (the game decides what a hole means: hold the last input, neutral, anything).

### 5.3 Client: sampling and sending

- At each flush step, for every index i in (k_last, K] the sample is the latched value (several ticks inside one
  long frame get the same value: the value was constant over them); k_last ← K. The client keeps each sampled
  index's codes for its window.
- **Window.** In every flush step, a stream's chunk carries indices [start, K] with
  start = max(a + 1, d): a is the newest index the server stated received (§5.5); d is the oldest index whose tick
  began at most J/`stateRate` + 1/60 s ago. A copy older than that can't arrive before its playout (derived in §6.1).
  No chunk when start > K. So a chunk holds at most J + 2 indices, and the protocol cap is 33 (J ≤ 31): rule 2.
- **Chunk** (a run chunk of the stream's id in the upstream unreliable toc):

```
stream chunk := id:u(w) count−1:EG0 first:u12 rp:u1 ref:u1 [back:EG0]
                copy(first) copy(first+1) … copy(first+count−1)
copy(i)      := same:u1 | '0' { changed:u1 [field single-row encoding] } per top-level field   -- vs index i−1
copy(first)  := ref = 0: the full single-row encoding
              | ref = 1: as copy(i), against index first − 1 − back
```

- `ref = 1` when the client holds an acked index a with K − a ≤ 63; then back = first − 1 − a. The server keeps
  the codes of its last 64 received indices, so a is held (derived: a ≤ server's newest ≤ K). A `ref` naming an
  index the server doesn't hold refuses the frame (rule 3: only a modified client sends it).
- `rp` is the parity of `stateRate` changes the client has applied (§5.6).

### 5.4 Server: receipt, playout, delivery

- **Receipt** (per player, per stream): `first` is extended to the value in [T_now − 2047, T_now + 2048], T_now
  the server's own state tick at decode (`v5.md` §4.4's rule against the server's tick). The decoder computes,
  before it allocates, how many of [first, first + count − 1] are new (neither received nor delivered) and charges
  that many elements (§7.1). It parses every copy, stores the new ones, and compares each redundant copy with the
  stored codes (§8.1).
- **Offset.** For each index on its first arrival, s_i = arrival − θ_i, θ_i = epoch + i / `stateRate` on the
  server's clock; o = the minimum s over the indices of the last 5 s (the core's timing window, chosen: `v5-collections.md`
  §11.1), kept by a monotone deque. o absorbs the one-way delay and the client's clock offset; it is the least
  delayed arrival, so every later arrival's lateness s_i − o ≥ 0.
- **Playout.** At each server `PostSimulation`, before the flush, an index i is due when now ≥ θ_i + o +
  J/`stateRate`. Due received indices are delivered in order. An index that arrives after it was due is delivered at
  arrival if no later index has been delivered yet, else discarded and counted (`inputsLate`). So every index
  plays at most J/`stateRate` plus one server step after its arrival, and the buffer holds at most the indices that arrived in the last
  J/`stateRate` s.
- **Steps 5–7** (`v5.md` §6.1; checks, claim requirement, validator, delivery) run per index at its playout, in
  index order. `Lync.perceived(player)` there returns the perceived value of the frame that first carried the index,
  kept with it. A check `"drop"` or a `false` validator drops the index (a jump in `index`).

### 5.5 The downstream ack

- **Field:** the downstream state-frame header gains `in := '0' | '1' index:u12` on connections with a welcomed
  namespace that declares a stream: the newest index received from that client. The client extends it to the value
  in (K − 4096, K] (it never acks an index the client hasn't sampled).
- **Only in state frames that exist anyway:** state frames are per player (`v5.md` §4.4), so the field costs no
  shared frame. With no `:newest()` rows to a player, no state frame goes and the client sends by the deadline
  window alone (measured in §6.1). A rows-less state frame per tick only to carry `in` would cost about 5 B down
  and 28 more ack bits up per tick (170 B/s at 20 Hz, 517 B/s at 60 Hz, derived) to save the difference between the
  two schemes of §6.1 (179–378 B/s at 20 Hz, 73–181 B/s at 60 Hz): a net loss at 60 Hz and at most 208 B/s at
  20 Hz, so it is not specified.
- **Width:** u12, as the sequences: aliasing needs an ack 4096 ticks stale (68 s at 60 Hz).

### 5.6 Loss, reordering, rekey, join, respawn, rate change

- **Loss upstream:** each index rides every flush until acked or past its deadline (§6.1).
- **Loss downstream (acks):** the client keeps sending until its deadline; only bytes change.
- **Reordering:** indices are absolute, the first arrival counts, copies are compared, late ones follow §5.4's
  rule; the replay window (`v5.md` §4.5) drops duplicated frames before decode.
- **Rekey:** unreliable frames under the old key are dropped for at most one round trip: loss.
- **Join:** a stream starts at the client's first `set` after its namespace's `WELCOME`; the first index sets o
  and plays J ticks after it arrives.
- **Respawn:** nothing in Lync; a game that resets its own input logic calls `resetChecks` as for any message.
- **`state.rate` change:** the client's indices switch to the new rate when it decodes `RATE`, so one round trip
  of chunks carries old-rate ticks. `rp` tells the server which (rate, epoch) a chunk's indices use; it keeps the
  current and previous pair and maps θ_i accordingly. Lync applies a new `state.rate` no sooner than 4 s after the
  previous change (chosen: the replay window's 64 frames last at most 4 s at 16 or more unreliable frames a second,
  which an active stream sends at 16 FPS or more, so no frame two changes old reaches decode).

## 6. `inputs`: what it saves and what it costs, measured

### 6.1 Delivery, latency and bytes (`inputs_sim.py`, verified by running)

600 s per run; the busy model's `move6` (42 bits; 1–3 fields change on 30% of ticks); `v5.md` §9's network each
way; one RNG per stream so every scheme sees the same losses per send. "Not delivered" is missing + late as a share
of indices due; latency is playout − sample, which is o + J/`stateRate` (o ≈ 50 ms here). Bytes are the stream's
chunk bits only (its frames exist for the game's other unreliable traffic or the ack). Copies are parsed per second.
Schemes: **R1** one copy; **tick** = one send per tick, since-ack, J + 1 indices, `ref` (identical delivery to
fixed J + 1 copies and to the research's since-ack capped at 32); **flush** = §5.3's rule, a send every 1/60 s
flush, deadline window, since-ack, `ref`; **flush, no ack** = the same with no `in` field (a player with no rows).

| Loss, rate, J (latency) | R1 | tick: not delivered, B/s, copies/s | flush: not delivered, B/s, copies/s | flush, no ack: B/s |
|---|---|---|---|---|
| 5% Bernoulli, 20 Hz, J 1 (100 ms) | 5.017% | 4.949%, 113, 40 | **0.059%**, 306, 98 | 485 |
| 5% Bernoulli, 20 Hz, J 2 (150 ms) | 5.017% | 0.245%, 119, 60 | 0.000%, 326, 159 | 542 |
| 5% Bernoulli, 20 Hz, J 3 (200 ms) | 5.017% | 0.000%, 125, 80 | 0.000%, 332, 203 | 598 |
| 5% bursty, 20 Hz, J 2 (150 ms) | 5.438% | 3.617%, 121, 60 | **0.616%**, 330, 159 | 542 |
| 5% bursty, 20 Hz, J 5 (300 ms) | 5.438% | 1.062%, 128, 84 | 0.025%, 338, 211 | 710 |
| 15% bursty, 20 Hz, J 3 (200 ms) | 15.126% | 6.695%, 134, 80 | **0.455%**, 352, 205 | 598 |
| 5% Bernoulli, 60 Hz, J 1 (67 ms) | 20.750% | 20.677%, 453, 120 | 20.677%, 476, 167 | 549 |
| 5% Bernoulli, 60 Hz, J 3 (100 ms) | 5.042% | 0.056%, 528, 240 | 0.056%, 554, 293 | 672 |
| 5% bursty, 60 Hz, J 5 (133 ms) | 4.958% | 0.953%, 577, 360 | 0.953%, 591, 406 | 768 |
| 15% bursty, 60 Hz, J 5 (133 ms) | 14.623% | 2.822%, 592, 360 | 2.822%, 607, 406 | 768 |

What decides it:
- **Copies beyond the depth never help, exactly.** Fixed J + 1 copies, since-ack capped at J + 1 and since-ack
  capped at 32 deliver the same indices in every run (same loss realisation; `inputs_sim.out`): a copy sent α after
  its index's tick began arrives at offset ≥ α + the shortest transit, while the index is due at o + J/`stateRate`
  with o ≤ 1/60 s + the shortest first-copy transit, so a copy with α > J/`stateRate` + 1/60 s is late (derived,
  for a copy no faster than the window's fastest first copy). That is §5.3's deadline, and it replaces
  `MAX_PACKET_USERCMDS` 32: the cap follows from the declared depth, and the protocol bound is J_max + 2 = 33.
- **Depth must exceed the jitter, whatever the redundancy:** at J = 0 every scheme misses 99.0–99.7% (only the
  window's fastest arrival is on time); at 60 Hz J = 1 (16.7 ms below the 20 ms jitter range) 20.6–28.6%; with
  0.05 s jitter, 60 Hz J = 2 misses 24.4% and J = 3 1.27% (`inputs_sim.out`, last block). This is why the depth is
  the developer's: it trades latency (J/`stateRate`) against late inputs on that player's real jitter, which Lync
  can measure (§8.2) but whose acceptable miss rate is a property of the game.
- **Resending every flush is what makes small depths work below 60 Hz:** at 20 Hz it cuts not-delivered from
  4.949% to 0.059% at J = 1, 3.617% to 0.616% at J = 2 (bursty), 6.695% to 0.455% at J = 3 (15% bursty), for 2.6–2.7×
  the chunk bytes (306–352 B/s, at most 2.1% of `inbound.unreliable.bytes`' 16,384 B/s). At 60 Hz flush and tick are
  one cadence (the extra 1/60 s of deadline adds 2–5% bytes and no delivery).
- **The ack plus `ref`** saves 37–52% of upstream chunk bytes at 20 Hz (306–338 against 485–710 B/s) and 13–23% at
  60 Hz; `ref` alone saves 3–34% against since-ack without it (`inputs_sim.out`, `ack,C=J+1` against
  `ack+ref,C=J+1`), because the first copy is a delta instead of 42 bits.
- **Downstream:** `in` is 13 bits per state frame (12 + presence), 33 B/s at 20 Hz and 98 B/s at 60 Hz when every
  tick carries a state frame (derived).

### 6.2 CPU (`inputs_cost.luau`, verified by running) and memory

- **Server parse per redundant copy** (`move6`, every copy rebuilt into locals, only new indices stored):
  unchanged copies 28.5–44.2 ns native, 64.9–154 ns interpreted; one in three changed 50.1–64.7 ns native,
  112–181 ns interpreted; a one-copy chunk 91–104 ns native. At the flush scheme's 98–406 copies a second: at most
  406 × 64.7 ns = 26 µs/s per player native (derived).
- **Server per delivered index:** one element of decode plus step 5–7 (220–420 ns per message native, `v5.md` §6.1),
  `stateRate` of them a second: 20–60 per stream per player, against the busy model's 60 input messages.
- **Client:** encode per flush of up to J + 2 copies, unmeasured; bounded by the copies a second above times one
  single-row encode each.
- **Memory per (player, stream):** server: 64 received indices' codes (64 × leaves × 8 B: 3 KB for `move6`), the
  offset deque (at most 5 s × `stateRate` entries of 16 B: 4.8 KB at 60 Hz), 33 lateness counters, the perceived
  value of each buffered index; client: the window's codes (at most 33 × leaves × 8 B).

## 7. `inputs`: budgets, checks, interest, rewind, Server Authority

### 7.1 Which budget each copy counts against

| What | Bucket | Why |
|---|---|---|
| the frame | `inbound.unreliable.frames` | chunks ride the flush's first unreliable frame; a stream adds frames only for a client with no other unreliable traffic: at most one per flush step, 60 of the 120 a second |
| every bit, redundant copies included | `inbound.unreliable.bytes` | 98–768 B/s measured (§6.1), at most 4.7% of 16,384 |
| each **new** index | `inbound.elements` | it becomes a delivered message (steps 5–7 and a handler call), the cost the element price p(L) bounds; charged before allocation from the header (§5.4) |
| each **redundant** copy | no bucket | it is parsed and compared, never allocated: at most 33 per stream per frame (rule 2), so per player ≤ Fu × Σ_streams 33 × c_copy; at the defaults 120 × 33 × 64.7 ns = 0.26 ms/s native for one `move6` stream (derived from `inputs_cost.out`), an added term of `v5.md` §7.5's bound |

- Charging redundant copies as elements would be exact but priced at p(L) ≈ 2.8 µs (L = 6) for work measured at
  28–65 ns, and an unmodified 60 Hz stream would take 167–406 of the 411 elements a second the derived default
  gives at L = 6: it would refuse an unmodified client's frames as `overElementBudget`. Counting new indices only
  costs 20–60 elements a second per stream.
- §7.5's 2 ms/s target then gains at most 0.26 ms/s per `move6` stream at the default frame budget; `report.md`
  should list the term per namespace with L and W_max (`v5-tooling.md`).

### 7.2 Checks, claims, validators

- Steps 5–6 run at playout in index order (§5.4), so `monotonic` and `maxRate` use the index as frame key and see no
  late frames; `maxRate`'s t is the playout time, θ_i + o + J/`stateRate`, which advances by exactly 1/`stateRate`
  per index while o holds: its `burst` then needs only the codec's decode error 2e, without the jitter term c of
  `v5-checks.md` §6.2 (derived; a change of o between two indices adds |Δo| × `rate`).
- `:claim()` leaves in a stream's `data` need a verifier before `connect` (`v5-checks.md` §7.3), as for events.
- `:input()` marks a leaf as input for the lint only; it is unrelated to streams (`v5-extensions.md`'s note stands).
- `limit` doesn't apply to streams: an unmodified client delivers one index per tick; a modified one can claim up
  to 33 new indices a frame, which `inbound.elements` bounds (§7.1).

### 7.3 Interest, rewind, Server Authority

- **Interest** doesn't meet streams (client→server).
- **Rewind:** a stream index's perceived value is that of the frame that first carried it (§5.4), so
  `Net.c:rewound(Lync.perceived(player), key)` inside a check or validator judges the index against what the client
  was shown when it sent it; a stream needs `perceived = true`-style full acks for exactness, so a stream definition
  carries the full ack on every frame holding its chunk (as `perceived` definitions do, `v5.md` §4.1: 28 bits when
  the frame would have carried `'0'`).
- **Server Authority:** simulation input belongs in `InputActions` (`state-sync.md` §8.1); streams are for games
  without it and for intents outside the simulation. Lync's index is not the engine's simulation step.

## 8. `inputs`: facts, unmodified clients, the open values, options

### 8.1 Facts and refusals

| Reason / rule | Exact trigger | Action | Evidence | Known causes on an unmodified client |
|---|---|---|---|---|
| fact `inputRewritten` | a copy of index i decodes to codes different from those first received for i | none: every redundant copy is discarded; the first stands | `index`, `firstSeq` and `seq` (extended upstream seqs of the two frames), `field` (1-based top-level field of the first difference) | none: the client re-encodes one stored code tuple per index; a Lync bug |
| rule 2 | a stream chunk with count > 33, `back` > 63, or two chunks of one stream in one frame | frame refused (`malformed`) | `rule` | none |
| rule 3 | `ref = 1` naming an index the server doesn't hold | frame refused | `rule` | none: the client refs only an index the server stated received, within 63 |

What `inputRewritten` protects: a modified client that sends one value for an index and a different one in a later
copy (to revise an input after seeing an outcome) gets the first value only, and the attempt is reported. What
defeats it: sending only one copy, i.e. delaying the input itself, which the playout shows as lateness and can't
distinguish from the network. An index far ahead of the server's tick needs no fact: playout is anchored to
arrivals (§5.4), so inflating indices gains no earlier delivery; a sudden jump only lowers o for 5 s and makes that
client's own in-order inputs late.

### 8.2 Counters and the lateness record

- `inputsLate` (index discarded after a later one was delivered), `inputsSkipped` (sum of index jumps between
  delivered indices: loss, lateness, `stop`), `inputCopies` (redundant copies parsed), per (player, stream).
- `Net.move:lateness(player)` returns a frozen array of 33 counts: indices of the last 5 s whose first arrival was
  ⌊(s_i − o) × `stateRate`⌋ = 0, 1, … 31 ticks after the earliest, and ≥ 32. The share late at depth J is
  Σ_{j ≥ J} count_j / total, exactly, for any J the developer considers: the measurement behind a per-player
  `playout({ depth, player })`, with no formula of Lync's own.

### 8.3 How it fails on an unmodified client

- **Depth below the player's jitter:** inputs late (`inputsLate`, `lateness`); at J = 0 almost every input
  (§6.1).
- **Bursts longer than the deadline window:** indices skipped (`inputsSkipped`).
- **Below 60 FPS:** fewer flush steps, so fewer resends per index (29.1 a second at 30 FPS); below `stateRate` FPS,
  several ticks per frame share one value.
- **A client hitch:** the ticks of the hitch are sampled at once with one value and arrive late.
- **Backgrounded mobile client:** no sends; skipped indices (whether it keeps receiving is pending, `v5.md` §10).
- **A `state.rate` change:** handled by `rp` (§5.6); a second change waits 4 s.

### 8.4 The open values of `v5-extensions.md`, settled

| Open value | Outcome | Evidence |
|---|---|---|
| the index | **the client's state tick**, not the upstream unreliable seq (the seq advances 0–n times per flush) | §5.1 |
| the copy cap | **derived from the depth**: an index is resent while its tick began at most J/`stateRate` + 1/60 s ago, so at most J + 2 copies; protocol bound 33 (J ≤ 31). Quake 3's 32 is not used | §6.1: copies past the depth delivered nothing in any run |
| the jitter-buffer depth | **the developer's, required** (`playoutUnset`), per definition and per player, 0–31 state ticks | trades J/`stateRate` of latency against late inputs on each player's jitter (§6.1); Lync reports `lateness` exactly |
| whether the server sets it from its jitter estimate | **no**: unlike D, nothing in Lync needs the depth to be one value both ends agree on beyond what `DEPTH` sends, and any formula (k × jitter) encodes an acceptable miss rate, which is the game's | §6.1, §8.2 |
| the header field's width | **`in := '0' \| '1' u12`** in downstream state frames only (13 bits), extended downward from the client's newest index | §5.5 |
| (added) resend cadence | every flush step, inside the deadline window | §6.1: 4.949% → 0.059% at 20 Hz, J = 1 |
| (added) which budget copies count against | new indices: `inbound.elements`; redundant copies: bytes only, with a bounded parse term | §7.1 |

Outcome: **adopt narrowed**: the stream's index is a tick (not the seq), the copy cap is derived rather than
declared, the depth has no server-chosen default, and the ack rides existing state frames only.

### 8.5 Options and constants

| Name | Where | Type | Unit | Range | Default | Cost |
|---|---|---|---|---|---|---|
| `Lync.stream({ data })` | shared schema | definition | — | fixed-width `data`; streams of a namespace ≤ 960 B at 33 copies | — | up 98–768 B/s per stream (§6.1); down 13 bits per state frame per connection; `stateRate` elements a second |
| `depth` | server view, `playout({ depth, player? })` | integer | state ticks | 0–31 | required (no default) | latency J/`stateRate` (+ o); server memory and §6.2's costs; a `DEPTH` row (1–2 B) per change |

| Constant | Value | Derivation |
|---|---|---|
| index | the client's state tick K | §5.1 |
| copies per chunk | ≤ 33 | J ≤ 31, window J + 2 |
| deadline | J/`stateRate` + 1/60 s | §6.1 |
| `ref` reach, server retention | 63 back, last 64 indices | chosen: 1.05 s at 60 Hz, 3.2 s at 20 Hz of ack delay before the first copy goes absolute |
| offset window | 5 s, minimum of first-arrival offsets | the core's timing window (`v5-collections.md` §11.1), chosen |
| `in`, `first` | u12 each | the sequences' extension rule (`v5.md` §4.4) |
| `DEPTH` | control type 4: id u(w), depth u5 | type 4 was unused |
| rate-change spacing | 4 s | 64 replay-window frames at ≥ 16 frames a second (§5.6), chosen |

## Implications

1. Adopt `acked` as `acked = true` on a collection in the shared schema, hashed after `sealed` (§1.1, §4.2).
2. Fix H = 32 state ticks as a protocol constant; it is the next power of two above the 19 the notify ring
   requires (§4.2, §2.1).
3. Use Unity's guarded linear predictor exactly as written (1/16 fractions, truncation toward zero), three
   baselines only when the collection has a linear leaf, n ≤ 2^43 (§1.3, §2.1).
4. Code acked rows as one column block per state frame with a reference baseline triple, an `own` column, and
   `gen`/`seg` implied by b0 (§1.4).
5. Schedule acked rows with §1.4's exact bound; refuse the piece-width bound, since it gives up the rate gain
   (§2.1).
6. Specify that an acked collection's client acks only state frames it accepted, and add the client decode rule of
   §1.5 (§1.5, §4.1).
7. State the cost plainly in the docs: 1.2 µs per (viewer, row) native, 24% of one core for the 100-player shooter
   at 20 Hz, for 2.35–4.89× fewer row bytes and full-rate rows inside the default budget (§2.1, §2.2).
8. Leave group-encoding of identical viewer blocks unspecified until a multi-viewer probe measures its hit rate
   (§3.1).
9. Replace "the upstream unreliable seq is the input index" with "the client's state tick is the input index"
   (§5.1).
10. Add `Lync.stream({ data })` as definition kind 4, fixed-width `data` only, with `set`/`stop` on the client and
    `playout({ depth, player? })` required on the server (§5.2, §8.5).
11. Resend each index at every flush step until acked or past J/`stateRate` + 1/60 s; drop the 32-copy cap
    (§5.3, §6.1).
12. Carry the server's newest received index as `in := '0' | '1' u12` in state frames only; send no rows-less state
    frames for it (§5.5).
13. Charge new indices to `inbound.elements` and leave redundant copies to the byte bucket; add the parse term of
    §7.1 to `v5.md` §7.5's bound (§7.1, §6.2).
14. Run checks and validators per index at playout, keyed by index, with the first frame's perceived value; give
    stream frames the full ack, as `perceived` definitions have (§7.2, §7.3).
15. Give the depth no default and no server formula; ship `lateness(player)` so a developer can set per-player
    depths from exact counts (§8.2, §8.4).
16. Add the fact `inputRewritten` and no others; add counters `inputsLate`, `inputsSkipped`, `inputCopies` (§8.1,
    §8.2).
17. Use control type 4 for `DEPTH`, and space `state.rate` changes 4 s apart, with an `rp` parity bit per chunk
    (§5.6, §8.5).
18. Pending measurement for both: real-device jitter and loss on mobile, and the client's interpreted decode cost
    of acked blocks on low-end phones (§2.2, §6.1).
