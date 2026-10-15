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

## Checklist

- [x] 1. `acked`: mechanism in Lync's terms
- [ ] 2. `acked`: what it saves and what it costs, measured
- [ ] 3. `acked`: encode-once, `FireAllClients`, budgets, interest, rewind, decoys
- [ ] 4. `acked`: unmodified clients, refusals, the open values, options
- [ ] 5. `inputs`: mechanism in Lync's terms
- [ ] 6. `inputs`: what it saves and what it costs, measured
- [ ] 7. `inputs`: budgets, checks, interest, rewind, Server Authority
- [ ] 8. `inputs`: facts, unmodified clients, the open values, options
- [ ] 9. Implications

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
- **Linear leaves** (guarded linear prediction, Unity's `GhostDeltaPredictor`, verified by reading
  `com.unity.netcode` `GhostDeltaPredictor.cs` via its public mirror): `t.number`, `t.angle`, the three columns of
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
  sharing it cost 1 bit or less each in `own`. Measured: 94–100% of rows use three baselines and almost all share
  the reference (§2).
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
  baseline tick the client doesn't hold, ages outside 1 … H − 1 or summing past H − 1, or nb = 3 in a collection
  with no linear leaf, refuses the frame. Only a server bug produces it; it is counted in `refusedFrames`.

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
