# Security-measure costs, re-measured

2026-10-15. Settles the performance and size figures the v5 docs use to refuse or narrow security measures, and
measures cheaper implementations a build could generate. Item numbers R1–R40 are from
`research/security-refusals.md`.

**Host and tools.** CLI VM only: Luau 0.742 built from the vendored source (`.data/projects/luau`, Release,
gcc 13.3) with `luau -O2` (interpreted, the Roblox client case) and `luau -O2 --codegen` (native, the Roblox server
case when its scripts are native); Luau 0.740 (the skill's pinned toolchain) for `remarks` and cross-checks;
python-zstandard 0.25.0 (libzstd 1.5.7). Intel Xeon 2.1 GHz, 4 cores, shared machine. **CLI timings do not
transfer exactly to Roblox**: Roblox servers run native code only for scripts marked native, clients are
interpreted, devices (phones especially) are slower, and engine costs (remote calls, `FireAllClients`, capability
errors, compression) cannot be measured here.

**Method.** `harness.luau`: every case of a comparison runs once per round, in order, after a warm-up round; 11
rounds; reported as median ns per iteration with min–max, and the median (range) of the per-round ratio to the
first case, the baseline in the same run. `run.sh` runs each probe 3 times interpreted and 3 times native into
`<probe>.out`. Figures below quote the medians of those runs unless marked otherwise.

## Checklist

- [x] 1. Runtime field shuffling 2–3x per record write (`field_order.luau`)
- [x] 2. Masking: +62–272% bytes after zstd; CPU per byte at the tag's rate (`mask_bytes.py`, `mask_cpu.luau`)
- [x] 3. Downstream tags: a PRF per recipient ≤ 3% of a core; ends `FireAllClients` (`downstream_tag.luau`)
- [x] 4. Per-session upstream id shuffle: ~20,000-slot decode table (`id_shuffle.luau`)
- [x] 5. Low-order watermarks: per-viewer encoding cost (`per_viewer.luau` part A)
- [x] 6. Decoys: per-viewer re-encode and pool slots (`per_viewer.luau` part B)
- [ ] 7. Caller probe on every call ≤ 0.2 ms/s at 60/s (`caller_probe.luau`)
- [x] 8. `tag.cover` 16,384 default ≤ 0.23 ms/s per player; 0.022 / 0.0035 µs/B (`tag_cover.luau`)
- [ ] 9. Clock beacon: one 66-slope fit per 5 s per player (`clock_fit.luau`)
- [ ] 10. Canary scan up to 256 B: per-offset lookup cost (`canary_scan.luau`)
- [ ] 11. Other figures used to refuse or narrow a measure (`tag_cover.luau`, `per_viewer.luau`, `enum_rotation.luau`, `getfenv_deopt.luau`)
- [ ] 12. R39: an unused per-frame transform hook slot vs none (`frame_hook.luau`)

## Results

### 1. Runtime field shuffling "2–3x per record write" — **false** (as a cost of shuffling)

Source: `v5-changes.md:105`, `:558`; R4. The figure is `research/client-security-build.md` §2.3's `writeHit`, a
3-field byte record written by straight-line code against a loop over a table of per-field closures, interpreted
only. Probe: `field_order.luau` (record and generated codecs from `gen_field_order.py` →
`field_order_gen.luau`), output `field_order.out`. 78-bit record (bool, `t.int(0,100)`, `t.int(1,2^16)`, three
`t.number(-2048,2048,1/32)`), v5 single-row bits. Medians of 3 runs, ratio to generated seed 0 in the same run:

| Encode one record | interpreted ns | ratio | native ns | ratio |
|---|---|---|---|---|
| generated, seed 0 (baseline) | 338 | 1.00 | 72 | 1.00 |
| generated, another fixed order (per-build rotation) | 336 | 1.01 | 74 | 1.03 |
| generated pool of 16 orders, chosen per message (per session or per player) | 336 | 1.04 | 74 | 1.05 |
| generated pool, encoder bound once per session | 331 | 1.00 | 74 | 1.05 |
| generated read-modify-write, constant offsets | 337 | 1.03 | 72 | 1.06 |
| generated read-modify-write, per-session offsets as upvalues (any of 720 orders) | 366 | 1.14 | 65 | 0.92 |
| table-driven runtime path, name order | 618 | 1.92 | 239 | 3.37 |
| table-driven runtime path, per-session order | 642 | 2.02 | 236 | 3.32 |

| Decode one record (server, per player) | interpreted ns | ratio | native ns | ratio |
|---|---|---|---|---|
| generated, seed 0 | 255 | 1.00 | 54 | 1.00 |
| generated pool, chosen per message | 255 | 1.01 | 60 | 1.12 |
| generated per-session offsets (closure) | 271 | 1.06 | 54 | 1.05 |
| table-driven, per-session order | 578 | 2.32 | 213 | 4.06 |

Original 3-field byte record, reproduced: closure table 2.25x interpreted (162.7–194.0 ns against 70.2–81.3),
**3.47x native**; straight line with per-session byte offsets 1.16x / 1.09x.

- The 2–3x is the generated-versus-table-driven gap (which is 3.3–4.1x native here), not shuffling: on the table
  path a per-session order costs +4% interpreted, −1% native against name order.
- A build can give per-session or per-player order on the generated path at 0–14% per record (0–12% per decode):
  a pool of generated orders indexed per session, or straight-line code with per-session field offsets held as
  upvalues (no pool, every order). Bytecode: about 2.1 KB per extra pooled order for this record (encoder plus
  decoder; `luau-compile -O2 -g0`: 5,415 B for 1 order, 7,490 B for 2, 36,888 B for 16); the offset form adds one
  closure per session and no per-order code.
- Size: 0 bits; v5 single rows have no alignment inside a row and string bytes go to the tail, so the draft-wire
  "up to 7 padding bits per string field" (client-security.md §3.4) does not apply (derived from `v5.md` §4.1–4.2).
- Tool: Luau 0.742 CLI, `-O2` and `-O2 --codegen`; round-trip of all 16 orders and the offset form checked in the
  probe.

### 3. Downstream tags: "a PRF per recipient costs ≤ 3% of a core and ends `FireAllClients`" — **true native up to 1 KB frames; false interpreted and above 1 KB; `FireAllClients` part inconclusive (engine)**

Source: `v5-changes.md:102` (draft 2: "0.48–5.5 µs native each … at 100 players × 60 Hz up to about 3%"), `:555`
(3.5: cost no longer the reason); R1. The 3% is 100 × 60 × 5.5 µs, the draft-1 probe's 1024 B native figure
(`probes/review-redundancy/halfsiphash_cost.out`), i.e. every downstream frame 1 KB and at 60 frames/s; the busy
model sends 80 downstream frames/s (60 reliable + 20 unreliable, `v5.md` §4.1). Probe: `downstream_tag.luau`,
output `downstream_tag.out`; the fast HalfSipHash in `hsip.luau` is checked against the reference port of
`probes/design-3.5/golden_tag32.luau` (and that port against the published HalfSipHash-2-4 vector `a9 35 9f 5b`)
on 405 frames. Time per frame sent to 100 recipients, share of one core at 80 frames/s (medians of 3 runs):

| Frame | per recipient, loop | per recipient, unrolled ×4 | once per frame + per-recipient 2-word PRF | per recipient, header only (16 B) | per recipient, counter only | per-recipient `buffer.copy` |
|---|---|---|---|---|---|---|
| native 64 B | 30.6 µs, 0.24% | 35.3 µs, 0.28% | 7.4 µs, 0.06% | 24.7 µs, 0.20% | 19.5 µs, 0.16% | 0.03% |
| native 256 B | 110 µs, 0.88% | 80.6 µs, 0.64% | 8.8 µs, 0.07% | 25.2 µs, 0.20% | 19.6 µs, 0.16% | 0.03% |
| native 512 B | 196 µs, 1.6% | 126 µs, 1.0% | 8.8 µs, 0.07% | 23.3 µs, 0.19% | 18.4 µs, 0.15% | 0.03% |
| native 1024 B | 418 µs, 3.3% | 256 µs, 2.0% | 11.6 µs, 0.09% | 24.8 µs, 0.20% | 19.1 µs, 0.15% | 0.03% |
| native 4096 B | 1662 µs, 13.3% | 960 µs, 7.7% | 24.1 µs, 0.19% | 24.5 µs, 0.20% | 19.2 µs, 0.15% | 0.11% |
| interpreted 256 B | 8.3–8.9% | 6.5–7.0% | 0.76–0.79% | 1.0–1.1% | 0.75% | — |
| interpreted 1024 B | 32–34% | 24–30% | 1.0–1.2% | 1.1–1.2% | 0.77% | — |

(Interpreted rows: range over the runs. At 60 frames/s multiply by 0.75.)

- Per-recipient PRF over the whole frame: ≤ 3% of a core only natively and for frames up to about 1 KB (the
  compression study's shooter frames are 100–560 B: 0.4–1.7% with the loop, 0.3–1.1% unrolled). Interpreted —
  which is what a Roblox server runs unless Lync's modules are native — it is 8–34% at 256–1024 B.
- Cheaper schemes a build can emit: hash the shared frame once (64-bit HalfSipHash-1-3 under a per-frame server
  key) and give each recipient a 2-word PRF of (digest ⊕ its count) under its own key: 0.06–0.19% native and
  0.7–2.0% interpreted at 100 players, flat in frame size. Tagging only the counter and header: 0.15–0.20%
  native, ~1% interpreted.
- `FireAllClients`: any per-recipient tag makes each recipient's bytes differ, so broadcast becomes 100 calls;
  the CLI-visible part (100 frame copies) is 0.03–0.11% of a core; the engine's per-call and per-recipient cost
  cannot be measured here (`v5.md` §10, "engine bytes per call"). The once-per-frame scheme still ends broadcast
  unless the per-recipient 4 B travel apart from the shared frame, which this probe did not test.
- Native 4 KB frames reach 7.7–13.3%: the "≤ 3%" holds for the input size it was derived at, not as a bound.

### 4. Per-session upstream id shuffle: "a decode table of ~20,000 slots" — **true count, cost negligible; tables are not needed**

Source: `client-security.md` §3.4, `v5-changes.md:104`, `:557`; R3 (slots derived as 200 × 100, bytes per slot
never given). Probe: `id_shuffle.luau`, output `id_shuffle.out` (memory by `collectgarbage("count")` before and
after, identical in all 6 runs).

| 100 players × 200 ids | memory | decode per message, interpreted | native | setup per player at join, interpreted | native |
|---|---|---|---|---|---|
| per-server table (design today, baseline) | one table | 24.6 ns | 7.95 ns | — | — |
| per-player Luau tables | 319 KB (16.3 B/slot) | 35.8 ns (1.46x) | 9.96 ns (1.26x) | 24.8 µs | 5.2 µs |
| per-player buffers (u8) | 22 KB (1.13 B/slot) | 33.6 ns (1.36x) | 8.29 ns (1.05x) | 28.5 µs | 5.9 µs |
| pool of 16 build-generated tables, index per player | 51 KB total | 35.1 ns (1.46x) | 10.5 ns (1.35x) | — | — |
| XOR with a per-session w-bit mask (ids ≥ count are rule 7) | 1 number per player | 39.3 ns (1.62x) | 10.7 ns (1.32x) | 0.09 µs | 0.003 µs |
| affine map mod count | 2 numbers per player | 40.2 ns (1.64x) | 8.96 ns (1.14x) | 1.6 µs | 0.49 µs |

- 20,000 slots is right; as bytes it is 319 KB as Luau tables or 22 KB as buffers per server, and 0 with a
  per-session XOR or affine map (one or two numbers per player). Lookup adds 0.3–2.8 ns native per message
  (11–16 ns interpreted); the per-player cases include fetching the player's table once per 8-message frame,
  which the baseline loop does not do, so the deltas are upper bounds.
- Zero wire bytes: every variant keeps u(⌈log2 count⌉) ids. A build-time pool trades per-player variation for
  memory; the XOR or affine maps need no table and no build step, but are structured (one known message reveals
  the XOR mask), which matters only against the reader the design already assumes reads the key.

### 8. `tag.cover` 16,384 default: "≤ 0.23 ms/s per player on the server; 0.022 µs/B interpreted, 0.0035 native" — **false as a bound; the per-byte figures are implementation-dependent (native beaten by a generated form, interpreted not reproduced)**

Source: `v5.md` §7.5 `tag.cover` row, §4.5; `v5-changes.md:549`. The 0.23 ms/s is 65,536 B/s (the two lanes'
default `inbound.*.bytes` rates) × 0.0035 µs/B; the per-byte figures are the build's 1024 B hashes divided by
1024 (`probes/build/results/579015b.json`, `c91960e.json`), so they include the per-hash fixed cost spread over
1 KB. Probe: `tag_cover.luau`, output `tag_cover.out`; frames 0–16,384 B, `v5.md` §4.5 input layout, checked
against the reference port. Medians of 3 runs ("marginal" = (t(16,384) − t(1024)) / 15,360 B):

| HalfSipHash-1-3/32 | fixed (0 B frame) | marginal ns/B | whole 1024 B ns/B | 65,536 B/s + 360 frames/s per player |
|---|---|---|---|---|
| native, generated loop | 0.21–0.25 µs | 3.82–3.87 | 3.9 | 0.33–0.34 ms/s |
| native, unrolled ×4, rotates nested in xors | 0.19–0.23 µs | 2.15–2.20 | 2.4–2.5 | 0.21–0.22 ms/s |
| interpreted, generated loop | 1.17–1.35 µs | 37.5–38.7 | 38.4–39.0 | 2.9–3.0 ms/s |
| interpreted, unrolled ×4, nested | 0.94–1.04 µs | 27.9–33.4 | 29.3–30.4 | 2.2–2.5 ms/s |

- Native: the build's 0.0035 µs/B reproduces for a plain loop (3.9 ns/B); a generated unrolled form with each
  rotate nested in its xor gets 2.2 ns/B. Interpreted: this probe's best is 28–33 ns/B, not the build's 22; the
  draft-1 probe (`review-redundancy/halfsiphash_cost.luau`) re-run on both 0.740 and 0.742 gives 38–40 µs per
  1024 B, so the gap is in the implementation, and the build's source (`f1fbfd7`) is not in this clone to compare.
  The client pays this rate for its own frames.
- The 0.23 ms/s omits the fixed cost per frame: at the default frame budgets (120 + 240 frames/s) it adds
  0.07–0.09 ms/s, so the bound is 0.33 ms/s with a plain loop and 0.21–0.22 ms/s with the unrolled form.
- It is not a bound on what a client can make the server hash: `v5.md` §6.1 step 2 tag-checks over-budget
  reliable frames ("so the count stays in step"), so tagged bytes are limited by what the engine delivers, not by
  `inbound.reliable.bytes`. Derived: at the documented ~500 calls/s per client (client-security.md §2.1) of
  16,384 B frames, 18 ms/s per player native unrolled (1.8% of a core), 31 ms/s with the loop, about 230 ms/s
  interpreted; whether the engine delivers 8 MB/s from one client is unmeasured. Hashing only `min(cover,
  bucket tokens)` bytes of an over-budget frame, or the count alone, would restore the bound.
- Claim 11(b) and (c) from the same runs: HalfSipHash 2-4 costs 1.8–1.9x 1-3 per byte (client-security.md's "about
  twice": **true**); a 64-bit output costs +3–10% at ≥ 1 KB and +16–39% at ≤ 64 B (fixed +25–40 ns native, +0.3–0.4 µs
  interpreted), against "a longer finalization per frame" (R28: **true**, and small).

### 5. Low-order watermarks: "Cost: per-viewer encoding" — **true in kind, small in size** (for `:newest()` rows)

Source: `v5-changes.md:115`, `:561`; R17 (asserted, no figure). Probe: `per_viewer.luau` part A, output
`per_viewer.out`. One viewer's 32 of 64 `:newest()` rows (slot u6, `t.vector3` 3 × u18, `t.rotation(9)`, 12 B
each) per state tick; the shared rows are encoded once per tick and copied per viewer today. Medians of 3 runs:

| Per viewer per state tick | interpreted | ratio | native | ratio |
|---|---|---|---|---|
| copy, encode-once (baseline) | 1.40 µs | 1.00 | 1.18 µs | 1.00 |
| per-viewer re-encode from cached codes, mark in the low bit of x, y, z | 6.06 µs | 4.17 | 1.02 µs | 0.88 |
| copy, then XOR the 3 low bits at build-known offsets | 2.71 µs | 1.84 | 1.21 µs | 1.07 |

- The rows are already per viewer, so a watermark adds −12% to +7% natively (the per-row `buffer.copy` call costs
  as much as re-encoding from cached codes) and +84% interpreted with the patch. At 100 viewers × 20 state
  ticks/s that is under 0.03 ms/s native. The probe checks that copy + patch gives the bytes of the marked
  re-encode.
- Not measured: marking reliable (column-coded) fields, which would need the per-viewer chunk re-encode measured
  under claim 6. The 3.5 reasons that are not cost (one rounding to twice the step strips it; it breaks step/2
  precision) are not performance claims and are not tested here.

### 6. Decoys: "one re-encode of each changed partition chunk per flush and the decoys' bytes … pool slots" — **true; the re-encode is the dominant cost, about one extra chunk encode per decoy viewer per flush at d = 1, and halved by reusing the shared chunk's k**

Source: `v5-integrity.md` §8 (`maxPerViewer` row), `v5-changes.md:554` (range widened to 1–256). Probe:
`per_viewer.luau` part B, output `per_viewer.out`. A reliable partition state chunk, column-coded as `v5.md` §4.3
(this probe's encoder: modes zero and EG-k, every k costed), 19 changed records × 5 int columns, with the viewer's
d decoys interleaved by slot. Medians of 3 runs, per viewer with decoys per flush in which the partition changed:

| d decoys | copy (viewer without decoys) | re-encode, full k search (design) | re-encode, shared chunk's k | re-encode, shared k sums + deltas | behaviour + diff | bytes (full / shared k) |
|---|---|---|---|---|---|---|
| native, d = 1 | 34 ns | 19.3 µs | 9.9 µs | 12.8 µs | 0.21 µs | 68 / 68 B |
| native, d = 16 | 35 ns | 33.0 µs | 18.4 µs | 38.0 µs | 0.24 µs | 140 / 144 B |
| native, d = 256 | 41 ns | 247 µs | 140 µs | 277 µs | 0.32 µs | 920 / 1072 B |
| interpreted, d = 1 | 43 ns | 99 µs | 28 µs | 45 µs | 0.28 µs | |
| interpreted, d = 16 | 39 ns | 158 µs | 49 µs | 191 µs | 0.26 µs | |
| interpreted, d = 256 | 46 ns | 1222 µs | 402 µs | 1353 µs | 0.43 µs | |

The shared chunk itself costs 16.7–17.2 µs native and 81–88 µs interpreted to encode once per flush.

- Per decoy viewer the re-encode is about 1.2x one shared-chunk encode at d = 1 (native), 2x at d = 16 and 15x at
  d = 256, against 34–41 ns for a copy. At 60 changed flushes/s: 1.2 ms/s per decoy viewer at d = 1 (0.12% of a
  core), 15 ms/s at d = 256 (1.5%). This probe's column encoder runs at about 2x the build's measured ns/value
  (`probes/build/results/`), so the absolute figures are upper bounds; the ratios are what carries.
- Cheaper and still canonical-decodable: mode and k are free choices (`v5.md` §4.3, §4.8), so the per-viewer chunk
  can reuse the shared chunk's k per column: 1.8–2.0x faster native (3.0–3.5x interpreted), +0–17% bytes on the
  decoy viewer's chunk (+4 B at d = 16, +152 B at d = 256). Updating the shared k-cost sums with only the changed
  rows is exact (checked byte-identical) but no faster once decoys outnumber the real rows.
- The behaviour call and diff (0.2–0.3 µs native) confirm `v5-integrity.md`'s 236 ns.
- Pool slots (derived, not timed): the pool takes `maxPerViewer` of `maxRecords` slots. At the default
  `maxRecords` 1024, d = 256 leaves 768 slots for live records and the reuse delay; keeping 1024 for them needs
  `maxRecords` 1280, one more bit (⌈log2 1280⌉ = 11) in every slot field of that collection.

### 2. Masking or whitening: "+62–272% bytes after zstd; CPU per byte at the tag's rate" — **bytes: false for v5 frames (0% for the bit section and for typical tails); CPU: true at best, a generated keystream runs at 0.2–0.8x the tag's rate**

Source: `client-security.md` §3.7 and `probes/client-security/zmask.out` (Python zstd level 3, synthetic
*draft-wire* byte-aligned frames masked whole, no raw fallback); `v5-changes.md:103`, `:556`; R2.

**Bytes.** Probe: `mask_bytes.py` (run `python3 -I mask_bytes.py <zstandard dir> ../compression`), output
`mask_bytes.out`. v5-shaped frames: the compression study's `col_bits_pred` layout as the bit section and inline
strings as the tail (`probes/compression/sim_mixed.py`), the engine model of `probes/compression/wire.py` (raw
under 100 B; zstd level 1 or 3, with and without raw fallback), 597 frames per model:

| Model (bit section + tail, mean) | plain | mask bits only | mask tail only | mask both |
|---|---|---|---|---|
| tycoon 10 Hz (183.4 + 12.8 B), level 3, fallback | 196.0 B | +0% | +0% (196.2) | +0% |
| shooter 20 Hz (173.2 + 4.6 B) | 177.8 B | +0% | +0% | +0% |
| shooter 60 Hz (100.3 + 1.3 B) | 101.5 B | +0% | +0% | +0% |
| mmo 20 Hz (94.2 + 1.2 B) | 95.5 B | +0% | +0% | +0% |

The same holds at level 1 and without fallback (tycoon 204.6 → 205.2 B masking the tail). Large tails behind an
80 B shooter bit section (level 3, fallback): 600 B of item and player names 508 → 506 B masking bits (−0.4%) and
508 → 680 B masking the tail (+34%); 3,240 B of names 398 → 402 B (+1.0%) and 398 → 3,320 B (+734%). The draft-wire
frames reproduce the research's figures: whole-frame masking +36–67% on input-like frames and +91–267% on
chat-like frames of 256–4096 B with fallback (+41–268% zstd-only).

- The +62–272% is the cost of masking *compressible byte-aligned* data; v5's bit section does not compress, so
  masking it costs 0 B, and the per-frame tails in these models are 1–13 B, also 0 B. Only a large compressible
  tail (catch-up names, chat logs, user strings) pays, which masking the bit section alone avoids.

**CPU.** Probe: `mask_cpu.luau`, output `mask_cpu.out`. Masking the bit section in place, per frame, medians of 3
runs, ratio to the tag over the same bytes in the same run:

| Bit section | tag rate (baseline) | PRF counter mode (2-word HalfSipHash per 4 B) | xorshift32 + Weyl keystream, 1 PRF per frame, per-build constants | 16 KB per-session pad, slice by count |
|---|---|---|---|---|
| native 64 B | 377 ns | 2.88x | 0.54x | 0.20x |
| native 256 B | 811 ns | 4.96x | 0.72x | 0.31x |
| native 1024 B | 2.57 µs | 6.42x | 0.83x | 0.36x (0.93 ns/B) |
| interpreted 64 B | 2.64 µs | 4.84x | 0.73x | 0.19x |
| interpreted 256 B | 8.20 µs | 6.56x | 0.73x | 0.23x |
| interpreted 1024 B | 30.1 µs | 7.09x | 0.65x | 0.24x (7.1 ns/B) |

- "At the tag's rate" is right for a keystream seeded once per frame and lower for a session pad; a PRF in
  counter mode is 3–7x the tag. All are involutions (checked). The pad repeats across frames (two frames masked
  with one slice XOR to the XOR of their plaintexts), and the xorshift stream is not a PRF; both are enough only
  against passive readers, which is the reader masking prices.
- A mask keyed per server and per tick, rather than per connection, keeps downstream frames identical for every
  recipient, so it need not end `FireAllClients`; per-connection keys do.
