# Lync v5: encoding and compression (as of 2026-10-15)

The question: how should Lync turn values into bytes, given that Roblox may zstd-compress
remote buffers on its own?
Read with `landscape.md` §2.2 and §4, `v5-attempt.md` §3 and `v4.md` §3–4. Nothing from them is repeated
here unless it is corrected.

**Labels.**
- **verified**: I ran it, or read the source.
- **documented**: official Roblox docs or a staff post.
- **reported**: a third party says it, with or without measurements.
- **unverified**: my inference.

**Probes.** All under `.data/docs/probes/compression/`:
- traffic generator: `traffic.py`
- layouts: `layouts.py`
- wire primitives: `wire.py`
- simulations: `sim_*.py`
- Luau benchmarks: `luau/*.luau`
- raw outputs: `results/*.txt`
- Studio probe: `studio/`

Python runs used python-zstandard 0.25.0, which bundles libzstd 1.5.7. Each frame is
compressed independently with checksum off and content size on.

Luau timings are from the pinned Luau 0.740 CLI at `-O2` on a shared 2.1 GHz Xeon:
- interpreted: the client case;
- `--codegen`: the server case.

Run-to-run noise on this machine is about ±25%. I report the best of 5 runs, with ranges
over 3 invocations where it matters.

## Verdict in eight lines

1. Roblox compresses each sufficiently large buffer argument with zstd. That much is
   documented. The threshold (≈100 B), the level, raw fallback and cross-call context are
   still unverified. The Studio probe in `studio/` settles them (§1.4).
2. Do not design the state wire for zstd. Use a **bit-packed, column-wise, residual-coded**
   layout: dirty and presence bits, prediction residuals, and a per-column Exp-Golomb/Rice
   order or mode chosen per frame. It beat every byte-aligned layout + engine zstd by
   1.3–2.4× in every model but the tycoon (a tie, 182 vs 183 B), above and below the
   threshold (§2).
3. That layout is incompressible, so the engine's level, threshold and fallback barely
   matter to it. Byte-aligned designs depend heavily on them (level −5 vs 1: 304 vs 171 B on tycoon).
4. Quantize floats. Lossless float coders (Gorilla, Chimp, ALP) cost 15–29 bits per position
   component. Quantized and predicted values cost 2–3.5 bits (§4).
5. Use guarded linear prediction (Unity's `GhostDeltaPredictor`). It halves position bits
   at 20–60 Hz compared with plain delta (§4.3).
6. Strings: append-only per-connection interning on the reliable lane, plus **templates** for
   formatted messages. Templates cut tycoon string bytes 6.5× against inline; interning alone
   cuts them 1.8×. Zstd adds nothing at these sizes (§5).
7. Trained entropy coders (static Huffman, rANS, adaptive arithmetic) gain 2–10% over the
   adaptive column coder and cost 46–106 ns/symbol interpreted. Refuse them in the core (§6).
8. 2023–2026 database float codecs (ALP, Pcodec, Elf, Camel, DeXOR) solve a different
   problem: long columns of decimal-origin data. The applicable lesson is structural:
   transform first (delta, column split), then code (OpenZL, Pcodec) (§7).

---

## 0. Method

**Traffic models** (`traffic.py`). Each model produces one server→client frame per tick for
one recipient, with random motion every frame:

| Model | Rate | Content per frame |
|---|---|---|
| shooter | 60 / 30 / 20 Hz | 29 visible players (a 100-player variant sees 99). Position at 1/32 stud (16-bit x, y, z), 12-bit yaw, 8-bit pitch, hp, anim, weapon, 4 flags. Shot and kill events (≈1.1/frame at 60 Hz). Strafe jitter, turns, jumps under gravity 196.2, aim flicks |
| racing | 60 Hz | 11 visible cars on a curved track at 30–300 studs/s. Position at 1/64 stud (19 bits), smallest-three rotation at 10 bits per component, velocity at 1/16 stud/s, steer, throttle, brake, rpm, gear, 2 flags. Collisions, boosts |
| mmo | 20 Hz | 400 entities in a 1000×1000 area. The recipient sees those within 280 studs (≈70; ≈0.4 enter/leave per frame). 50% idle, 35% wandering, 15% running. Position at 1/16 stud (18 bits), 8-bit yaw, anim, hp (16 bits), combat flag. Names on enter |
| tycoon | 10 Hz | ≈160 records: kind, level, 40-bit value counter, progress timer, owner, 2 flags. ≈60% change each tick (progress), plus money ticks. Purchase, money and notification events, with item names (Zipf over 200), chat and notifications |

**Layouts** (`layouts.py`). All carry identical information:

| Name | What it is |
|---|---|
| `abs_row_f32` | f32 floats, other fields byte-aligned |
| `abs_row_aligned` / `abs_row_bits` / `abs_col_aligned` / `abs_col_split` | Absolute quantized values: row with each field rounded up to whole bytes; row bit-packed; struct-of-arrays; struct-of-arrays with byte-plane split |
| `xor_row_aligned`, `xor_col_split` | Warp-style XOR of the whole buffer against the previous frame's buffer |
| `dlt_{row,col}_fixed`, `dlt_col_split` | Wrapped arithmetic delta at the field's own width (+ byte planes) |
| `dlt_{row,col}_varint` | Delta, zigzag, LEB128 |
| `hyb_mask_varint`, `hyb_pred_varint` | Bit-packed entity and field dirty masks + byte-aligned zigzag-varint columns of changed values; `pred` = residual vs guarded linear prediction |
| `dlt_bits_mask` | Gaffer-style: changed bit, field bit, then small/large/absolute value |
| `dlt_bits_class` | The v5 attempt: changed bit, field mask, 4-bit class code |
| `dlt_bits_eg` | Masks + Exp-Golomb with a per-field order trained offline |
| `col_bits_adapt`, `col_bits_pred` | **Column coder**, without/with prediction: per field over all persisting entities, a 2-bit mode chosen per frame. 0 = all zero; 1 = EG-k of every residual (4-bit k); 2 = sparse (EG-0 gaps + EG-k values); 3 = raw bits. Bools as a bit row, no per-entity masks |
| `col_bytes_adapt` | Byte-aligned analogue: per column a width byte, then a fixed 0–5 bytes of zigzag residual per value |

The entered/left set changes use the same encoding inside each family. In each layout the
events use the same family's encoding (aligned or bits).

**Engine model** (`wire.engine_len`). Buffers under 100 B are sent raw. Otherwise the size
is `min(raw, zstd)`. The "zstd3" column is the no-fallback variant.

**Lanes**:
- **reliable**: deltas against the previous frame (age 1), which is sound because the lane is ordered;
- **unreliable**: deltas against the last acknowledged frame ≈100 ms back (age 6 at 60 Hz,
  2 at 20 Hz, 1 at 10 Hz).

---

## 1. Roblox's engine compression

### 1.1 Evidence, claim by claim

| Claim | Evidence | Label |
|---|---|---|
| Buffers are compressed with zstd when "sufficiently large" | WheretIB (Luau buffer author), 2023-11-30, in the buffer announcement: "A sufficiently large buffer will be compressed before sending the data to the client/server". The compression "can identify patterns where individual bytes can be compressed to occupy less than 8 bits each". Reply the same day: "Current compression method that's being used is Zstd". 2023-12-13 edit: "Replication of the buffer type will receive updates to reduce data size even further" ([thread](https://devforum.roblox.com/t/introducing-luau-buffer-type-beta/2724894)) | documented (staff) |
| The engine compresses remote arguments and the unreliable limit is checked after encoding | UnreliableRemoteEvent reference, present by 2026-06-11: "Events with payloads larger than 1000 bytes are dropped. When this happens in Studio, a log message in the Output window indicates the number of bytes the event went over." And: "Like all events, the UnreliableRemoteEvent methods encode and compress certain object types, such as buffers, which shrinks the payload size and can make it difficult to verify whether you are under the limit prior to firing the event" ([creator-docs YAML](https://github.com/Roblox/creator-docs/blob/main/content/en-us/reference/engine/classes/UnreliableRemoteEvent.yaml), commit c1519e7) | documented |
| Limit counted after compression | Under the old 900 B limit, a 3855 B structured buffer arrived and 3875 B was dropped; repeated-number buffers of 10,000 B arrived ([thread 1](https://devforum.roblox.com/t/what-are-real-limits-of-data-being-sent-when-using-unreliableremoteevent/3038324), [thread 2](https://devforum.roblox.com/t/incorrect-size-of-data-being-sent-limit-specified-when-using-unreliableremoteevent/3048788), 2024-07). The earlier attempt's Studio check found zero buffers passed up to 8000 B, while random ones dropped from 990 B (`v5-attempt.md` §9) | reported ×2; consistent with the docs |
| Threshold ≈ 100 B | `RemotePacketSizeCounter/src/BufferSize.luau`, commit 2026-08-30: `COMPRESSION_THRESHOLD = 100`, `COMPRESSION_LEVEL = 0`, and the compressed size is used even when it is larger than raw. There is no derivation in the commit or README ([source](https://github.com/Pyseph/RemotePacketSizeCounter/blob/main/src/BufferSize.luau)). Pyseph in 2023: "compressed past a certain size, with an unknown limit" ([URE thread p10](https://devforum.roblox.com/t/introducing-unreliableremoteevents/2724155?page=10)) | reported, no method shown |
| Level | Forum guess "around level 3 I think" ([thread](https://devforum.roblox.com/t/high-performance-networking-let-engine-handle-it-or-use-custom-entropy-coder/4633845), 2026-05). PacketProfiler's level `0` is libzstd's "default", which is 3, *if* `EncodingService` passes it through. `EncodingService:CompressBuffer` defaults to level 1 ([docs](https://create.roblox.com/docs/reference/engine/classes/EncodingService); API dump 0.741: `compressionLevel: int = 1`) | unverified |
| Dictionary | No evidence of one. `CompressBuffer` has no dictionary parameter (API dump 0.741) | unverified (likely none) |
| Strings compressed? | Squash's bandwidth bench: strings of 1–8 repeated `'a'` grow linearly, 0.07 KB/s per character at 60 Hz ([benchmarks.md](https://github.com/Data-Oriented-House/Squash/blob/main/docs/RemoteEvents/benchmarks.md)). So short strings are not compressed. Long ones untested | reported |
| Per value, not per packet | The staff wording is about "a buffer". Roblox's own protocol precedent: in the reverse-engineered replication protocol (roblox-dissector, last commit 2020-10-07), join data (0x83/0x0B), region removal (0x0E), the schema (0x97) and physics blobs are each a self-contained zstd frame. Each is prefixed by `compressedLen u32` + `decompressedLen u32` and decoded with a fresh `zstd.NewReader` ([ExtendedReader.go](https://github.com/Gskartwii/roblox-dissector/blob/master/peer/ExtendedReader.go), [Packet83_0E.go](https://github.com/Gskartwii/roblox-dissector/blob/master/peer/Packet83_0E.go)). Remote calls in a short window are merged into one 0x83 packet ([Squash binary.md](https://github.com/Data-Oriented-House/Squash/blob/main/docs/RemoteEvents/binary.md)) | verified (2020 source); unverified for buffers today |
| No persistent context across calls or frames | **Blink's benchmark arithmetic.** It fires the same 100-entity × 6-byte array 1000 times per frame, and Blink batches all of it into one buffer per frame ([Entities.luau](https://github.com/1Axen/blink/blob/main/benchmark/src/shared/benches/Entities.luau), [client](https://github.com/1Axen/blink/blob/main/benchmark/src/client/init.client.luau)). It reports ≈42 on `Stats.DataSendKbps`, a property the docs define as *kilobytes* per second ([Stats.yaml](https://github.com/Roblox/creator-docs/blob/main/content/en-us/reference/engine/classes/Stats.yaml)). 42 KB/s at 60 fps is ≈700 B/frame, about one compressed copy of the 600 B array per frame. A context persisting across frames would make the steady state near zero, since the data is identical every frame | unverified inference, strong |

Sources disagree only on the threshold's existence. Staff say "sufficiently large", and
PacketProfiler says 100. I believe a threshold exists, because zstd's frame overhead
(≈6–13 B) makes compressing tiny buffers a loss. The value 100 is untested.

### 1.2 What each unknown would change

| Unknown | If… | Consequence for Lync |
|---|---|---|
| Threshold T | T ≈ 100 | Byte-aligned frames under 100 B travel raw at 8 bits/byte. This is the main reason the bit-packed coder wins small frames (§2) |
| Raw fallback | No fallback (always a zstd frame ≥ T) | Incompressible bit-packed frames ≥ T pay +9–13 B (`zstd3` column of §2.1: e.g. 102→111 B). That is still below every byte-aligned alternative. A mitigation is to split one large bit frame into two arguments under T, *if* compression is per argument |
| Level | Negative (fast) levels | Byte-aligned layouts lose most of their zstd gain. Tycoon `dlt_col_varint` costs 304 B at level −5 vs 171 B at 1. `abs_row_aligned` gets no compression at −1. The bit-packed coder is unaffected (§2.4) |
| Per argument vs whole call | Whole call | The sidecar instances array and the frame buffer would compress together, with no change to the design |
| Cross-call / cross-frame context | Exists | Warp-style XOR or "same bytes as last frame" would become nearly free, and a byte-aligned *absolute* layout with engine-side redundancy removal could compete. **This is the only outcome that would reopen the layout decision.** Current evidence says it does not exist |
| Unreliable limit before/after compression | After (documented) | Lync must size unreliable frames by their *post-engine* size. With an incompressible bit-packed frame, pre and post sizes are equal (+ fallback overhead), so the bound is predictable without calling `EncodingService` |
| Reliable vs unreliable | Different thresholds or levels | Nothing changes for the bit-packed state. It would only change where strings and blobs go |

### 1.3 How compression interacts with the two lanes

- **Reliable** (`RemoteEvent`): ordered, no limit relevant here. Deltas against the previous frame need no acks.
  Absolute catch-up keyframes (joins, new viewers) are large and partly compressible:
  - mmo keyframe `abs_col_split`: 830 → 688 B;
  - tycoon keyframe: 1765 → 1340 B.

  The engine helps there for free.
- **Unreliable** (`UnreliableRemoteEvent`): 1000 B after encoding (documented). Deltas must go
  against an acknowledged baseline. That costs 13–47% more bits than age-1 deltas at
  100 ms RTT (§2.1: shooter60 col_bits_pred 102 → 150 B; shooter20 165 → 186). Lync's batching bound is 1000 B
  minus call overhead. With incompressible frames, the encoder knows the exact size.

### 1.4 The Studio probe (`studio/`)

**Files and setup.** `studio/README.md` says exactly what to run (Local Server, 1 player,
3–6 min) and what to paste back:
- `LyncCompressionProbe.server.luau`, the server Script;
- `LyncCompressionProbe.client.luau`, the client LocalScript;
- `Samples.luau`, ten real frames from the models with libzstd sizes per level, written by
  `export_samples.py`.

The scripts type-check clean (`check --roblox`: luau-lsp 1.70.1, new solver, no
sourcemap), apart from one lint for the deprecated `version()` stamp.

**Method: the ruler.** Every unreliable fire is `(tag4, X, pad1100)`, so it always overflows.
- The engine's Output message "went over by N" gives N(X), which is captured with `LogService.MessageOut` on both peers.
- The on-wire size of X is N(X) − N(empty buffer).
- If no message carries a number (one forum quote shows a numberless variant: "Unreliable Event dropped as its payload is too large…" ([thread](https://devforum.roblox.com/t/unreliableevent-payload-warning/3981857))), the probe falls back to a binary search for the largest pad that is still delivered, with the client acking each fire.

**The tests:**

| Test | Fires | Decides |
|---|---|---|
| T2 | Zero and random buffers of 1–800 B, every byte from 90 to 110 | Threshold. Raw fallback (random cost ≈ L) vs always-zstd (≈ L + 9–13) |
| T3 | The 10 samples: on-wire size vs `CompressBuffer` at levels −7…22 and vs libzstd sizes | Fits `wire = len(CompressBuffer(level)) + c`. The level with a constant c across samples is the engine's level. Sizes below every level's mean a dictionary or other context |
| T4 | `(A, A)`, `(A, copy of A)`, `(A, B)`; 600-char strings `aaa…` vs random; a buffer inside a table | Per-argument vs whole-call compression; strings; nesting |
| T5 | 6 s scenarios at Heartbeat: fresh random 900 B vs **the same random 900 B every frame**, 450 B twice per frame, zeros, 90 B variants, the same on unreliable | Medians of `Stats.DataSendKbps` (server) and `DataReceiveKbps` (client). Cross-frame and cross-call context; Stats' unit (54 KB/s sent) |
| T6 | Reliable zeros of 90/99/100/101/110 B per frame | Reliable-lane threshold |
| T7 | Unreliable zeros of 4000/20000 B; random 980/990/1000 B | Limit after compression; exact random ceiling |
| C→S | T1–T3 subset with `FireServer` | Direction symmetry |

---

## 2. Shaping bytes for zstd

### 2.1 Results

Mean bytes per frame (`results/sim_layout.txt`, 300 frames, warm-up excluded). "eng" is
the engine model at zstd level 3 with threshold and fallback. "≥100" is the share of
frames at or over the threshold.

**Reliable lane (age 1), and absolute snapshots:**

| Layout | shooter60 raw → eng | shooter20 | racing60 | shooter100p@20 | mmo20 | tycoon10 |
|---|---|---|---|---|---|---|
| abs_row_f32 | 753 → 717 | 787 → 751 | 530 → 530 | 2689 → 2300 | 1292 → 1203 | 1725 → 1490 |
| abs_row_aligned | 434 → 431 | 468 → 458 | 321 → 321 | 1600 → 1412 | 881 → 757 | 1881 → 1466 |
| abs_row_bits | 353 → 353 | 381 → 381 | 242 → 242 | 1331 → 1331 | 654 → 654 | 1491 → 1376 |
| abs_col_split | 420 → 382 | 454 → 426 | 313 → 313 | 1551 → 1343 | 830 → 688 | 1765 → 1340 |
| xor_row_aligned (Warp) | 435 → 252 | 469 → 311 | 322 → 247 | 1601 → 896 | 882 → 178 | 1882 → 305 |
| xor_col_split | 421 → 193 | 455 → 260 | 314 → 234 | 1552 → 775 | 831 → 191 | 1766 → 260 |
| dlt_row_fixed | 406 → 246 | 440 → 316 | 311 → 238 | 1502 → 918 | 765 → 145 | 1569 → 244 |
| dlt_col_fixed | 392 → 209 | 426 → 284 | 303 → 235 | 1453 → 838 | 715 → 156 | 1453 → 189 |
| dlt_row_varint | 292 → 213 | 346 → 287 | 218 → 210 | 1178 → 822 | 415 → 114 | 966 → 241 |
| **dlt_col_varint** (best byte-aligned + zstd) | 278 → **170** | 332 → **248** | 210 → **202** | 1129 → **746** | 364 → **121** | 849 → **183** |
| hyb_pred_varint | 192 → 183 | 246 → 246 | 177 → 177 | 837 → 756 | 77 → 76 | 279 → 257 |
| col_bytes_adapt (pred) | 217 → 165 | 304 → 248 | 198 → 186 | 1110 → 728 | 326 → 115 | 664 → 238 |
| dlt_bits_class (v5 attempt) | 180 | 236 | 187 | 815 | 66 | 256 |
| dlt_bits_eg | 148 | 205 | 149 | 705 | 53 | 226 |
| col_bits_adapt | 129 | 187 | 141 | 634 | 67 | 182 |
| **col_bits_pred** | **102** | **165** | **124** | **562** | **51** | **182** |

**Unreliable lane (acked baseline ≈100 ms back):**

| Layout | shooter60 (age 6) | shooter20 (2) | racing60 (6) | shooter100p (2) | mmo20 (2) |
|---|---|---|---|---|---|
| dlt_col_varint + engine | 228 | 269 | 229 | 818 | 137 |
| hyb_pred_varint + engine | 223 | 262 | 203 | 828 | 86 |
| dlt_bits_eg | 189 | 220 | 178 | 758 | 63 |
| **col_bits_pred** | **150** | **186** | **151** | **631** | **62** |

The bit-packed rows show raw sizes. The engine adds nothing to them, because zstd fails to
shrink them and the fallback keeps them raw. Without fallback, add 9–10 B to frames of 100 B
or more. "Pick per frame", the min of col_bits_pred raw and dlt_col_varint + engine,
improved on col_bits_pred only for tycoon (182.4 → 180.2). The encoder does not need to
choose per frame.

### 2.2 Findings per technique

**Single-frame zstd on state.** Frames are 100–1500 B, and zstd at any level pays a frame
header of about 6–13 B, plus Huffman table descriptions, before it can start using
statistics.
- On quantized or bit-packed absolute data it does almost nothing (`abs_row_bits` → no change).
  This confirms and extends landscape §2.2.
- It does compress **byte-aligned delta** layouts by 1.3–8× (mmo `dlt_row_varint` 415 → 114),
  because those layouts are full of zero bytes and small byte values.
- **But it compresses them to about 1.3–2.4× the size of a well-designed bit code.**
  For example: shooter60 170 vs 102; mmo 121 vs 51; shooter100p 746 vs 562. The tycoon,
  dominated by all-zero columns, is the exception: a tie (183 vs 182).

The reason is simple. zstd's entropy stage is per frame, starts from nothing, and frames
are short. A bit code with a per-column order (a 4-bit k) is a two-parameter model that
needs no table. Gaffer reached the same conclusion with hand-tuned bit codes, and noted
that a context-aware arithmetic coder beat his best bit-packing by 25%
([snapshot compression](https://gafferongames.com/post/snapshot_compression/)). §6 tests
what is left of that gap once codes adapt per column: 2–10%.

**Row vs column (SoA).** Column order helps every byte-aligned layout under zstd:
- shooter60 abs: 431 → 383; delta-varint: 213 → 170;
- tycoon: delta-varint 241 → 183.

Like values sit next to each other, which helps zstd's literal coding and match finding.
For the bit-packed coder, columns are what make the per-column order possible: `dlt_bits_eg`
uses per-field k fixed offline (148), and `col_bits_adapt` uses per-column k chosen per frame
(129). **Use columns.**

**Byte-plane split** (Blosc shuffle, Parquet `BYTE_STREAM_SPLIT`):
- It helps only **absolute multi-byte** columns: mmo `abs_col_aligned` 738 → `abs_col_split` 688 (−7%), tycoon 1415 → 1340 (−5%).
- On residual columns it is neutral or worse: shooter60 `dlt_col_fixed` 209 → `dlt_col_split` 213; `col_bytes_split` ≈ `col_bytes_adapt`.

Residuals are mostly one byte already. Use byte planes only in byte-aligned catch-up
keyframes, if those stay byte-aligned. A column FOR (min + width) in the bit coder does
the same job better.

**XOR vs arithmetic delta (Warp).** XOR against the previous frame's buffer is
schema-agnostic. It is never the best:
- shooter60: `xor_col_split` 193 vs `dlt_col_varint` 170;
- mmo: `xor_row_aligned` 178 vs 114;
- tycoon: 305 vs 183.

A small numeric change flips many bits (0x7FFF → 0x8000). A changed field keeps its full
width. Varint deltas shrink, but XOR bytes do not. Warp's design
([Xor.luau](https://github.com/imezx/Warp/blob/master/src/Util/Xor.luau)) is a reasonable
zero-schema fallback, but Lync has a schema.

**Delta + zigzag + varint.** This is the best byte-aligned family under zstd. Raw, it is 25–55%
smaller than fixed-width deltas. After zstd it is 5–25% smaller. It is the right *byte-aligned*
choice for user payloads that must stay byte-aligned.

**Where bits belong** (masks and headers):
- Bit-packed dirty masks plus byte-aligned values (`hyb_*`) win when changes are sparse
  (mmo 76 B vs 121 B for `dlt_col_varint`). They lose when changes are dense (shooter60 183 vs 170;
  tycoon 257 vs 183), because zstd can do little with the mask bytes.
- The column coder makes masks unnecessary: a sparse column codes its non-zeros as gap/value
  pairs, and an all-zero column costs 2 bits.
- Gaffer's "changed cubes as index list vs bitmask, chosen per snapshot" is the same idea
  as the per-frame mode choice ([snapshot compression](https://gafferongames.com/post/snapshot_compression/)).

**Prediction.** Residuals against a guarded linear prediction (§4.3) cut col_bits from 129
to 102 B at shooter60 (−21%) and from 67 to 51 B on the mmo (−25%). The cut is smaller
at 20 Hz (187 → 165) and on unreliable baselines (169 → 150).

### 2.3 Why `col_bits_pred` is the layout

How it works, per frame:
1. **Set changes** (entered/left ids with absolute rows).
2. **For each field column** over the persisting entities, sorted by id:
   - compute residual r = value − prediction, or − baseline for non-motion fields;
   - zigzag it;
   - pick the cheapest of: all-zero (2 bits); EG-k for every row (2 + 4 bits + codes);
     sparse (gap/value pairs); raw.

   The simulations try every k. Do not shortcut k selection with a log2-of-mean rule (the
   JPEG-LS idea): trying only {k0−1, k0, k0+1} with k0 = ⌊log2(mean+1)⌋ found the best k for
   99–100% of position-residual, id-gap and large-value columns, but cost 6% extra bits on
   money deltas and 14% on mostly-zero mmo columns (verified on the `sim_ints` streams).
   Costing all 16 k is one pass per k over ≈30–100 values. That is cheap on a native server.
3. **Bools** as a bit row.

What it buys:
- One layout for every frame size. Below 100 B it is the smallest because nothing else is
  compressed. Above 100 B it is still the smallest, because the engine's per-frame zstd
  cannot learn the statistics in time.
- Robustness to the unknowns of §1: the frame is incompressible, so the engine level,
  threshold and dictionary barely matter. Fallback costs ≤10 B.
- Exact size before sending, which unreliable batching needs.

It costs (§3.2):
- decode: ≈35–70 ns per value interpreted, 11–16 ns native;
- encode: ≈14–16 ns per value native with an inlined accumulator.

### 2.4 Engine level sensitivity (byte-aligned only)

| Frame | raw | L−5 | L−1 | L1 | L3 | L6 | L19 |
|---|---|---|---|---|---|---|---|
| shooter60 `dlt_col_varint` | 271 | 186 | 177 | 161 | 161 | 162 | 157 |
| mmo20 `dlt_row_varint` | 398 | 126 | 109 | 94 | 96 | 94 | 81 |
| tycoon10 `dlt_col_varint` | 842 | 304 | 272 | 171 | 183 | 179 | 168 |
| tycoon10 `abs_row_aligned` | 1865 | 1865 | 1865 | 1450 | 1453 | 1451 | 1452 |

Negative (fast) levels skip Huffman coding of literals. A byte-aligned design that depends on
the engine could lose 40–75% of its expected gain, depending on a constant Lync cannot see.
Stripping the frame's 4-byte magic saves about 4 B (`magicless3`) and is irrelevant.

### 2.5 One buffer or two?

`sim_mixed.py`: a bit-packed state section plus a byte-aligned strings section.

| Model | One buffer | Two buffer arguments (+2 B) |
|---|---|---|
| tycoon | 239.3 | 241.6 |
| shooter | 219.5 | 221.5 |
| mmo | 116.0 | 118.0 |

Per-frame strings are ≈35 B and too small for zstd to matter. **One buffer per frame**, with the
byte-aligned tail (strings, user `buffer` and `string` payloads) after the bit section, so
any large text still gets compressed. Revisit only if T4 shows per-argument compression
*and* T2 shows no fallback.

---

## 3. Integer coding

### 3.1 Size (`sim_ints.py`, `results/sim_ints.txt`)

Bits per value for:
- raw;
- after engine zstd on that frame's chunk alone;
- inside about 600 B of consecutive frames. This third column flatters zstd: for
  `id_gaps` it finds cross-frame matches a real frame would not have.

| Stream (values/frame; H0 bits) | LEB128 | PrefixVarint | GroupVarint | StreamVByte | EG-k static | EG-k per chunk | Rice static | FOR | PFOR | Simple-8b | Class code (v5a) | Unity bucket |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| pos_pred60 (87; 1.83) | 8.0/8.0/3.0 | 8.0/8.0/3.0 | 10.0/7.5/3.5 | 10.0/7.2/3.5 | **2.11** | 2.16 | 2.28 | 4.78 | 2.89 | 3.49 | 4.76 | 2.79 |
| pos_delta20 (87; 4.90) | 8.1/8.1/5.8 | 8.1/8.1/5.9 | 10.0/8.3/6.3 | 10.0/8.4/6.1 | **5.92** | 5.93 | 6.02 | 7.62 | 7.34 | 7.52 | 7.26 | 5.96 |
| mmo_delta20 (406; 1.01) | 8.0/2.1/1.9 | 8.0/2.1/1.9 | 10.0/2.3/2.2 | 10.0/2.2/2.1 | **1.58**/1.28* | 1.59 | 2.33 | 6.28 | 1.97 | 3.66 | 4.38 | 2.44 |
| id_gaps (58; 3.77) | 8.0/8.0/1.1* | 8.0 | 10.1 | 10.1 | 4.56 | 4.62 | **4.13** | 6.33 | 4.84 | 5.51 | 6.68 | 4.96 |
| money_delta (25; 6.70) | 13.7 | 13.7 | 14.1 | 14.1 | **12.40** | 12.49 | 14.01 | 16.25 | 16.41 | 16.34 | 13.62 | 13.68 |
| money_abs (156; 10.2) | 28.5 | 28.5 | 25.9 | 25.9 | 23.6 | 26.9 | **22.8** | 23.4 | 23.5 | 31.9 | 27.2 | 28.2 |
| str_len (31; 4.35) | 8.0/8.0/5.1 | 8.0 | 10.0 | 10.0 | 6.09 | 6.25 | 5.88 | **5.45** | 5.71 | 7.29 | 8.76 | 7.86 |

\* Starred values come from the third column (consecutive frames concatenated), which the
footnote above warns flatters zstd. The others in those rows are raw sizes.

The bit codes are raw sizes. Engine zstd never shrank them on a lone frame chunk. It
shrank them only in the 600 B concatenations, where mmo zeros give long runs: 1.58 → 1.28.
Byte codes are shown as raw / engine / 600 B.

Readings:
- **Small residuals** (most state): EG-0/Rice-0 code at 2.1–2.3 bits against an entropy of 1.8.
  Every byte-oriented varint is 8 bits raw. Even with zstd on a 600 B frame they reach only
  3.0 bits, and on a lone frame chunk zstd does nothing. **Bit codes win by 1.4–3.8×.**
- **Medium deltas** (20 Hz positions): EG-k ≈ 5.9 bits vs ≥5.8 bits for varints + zstd at
  600 B and 8.1 bits otherwise. They are equal at best, and the bit code needs no threshold.
- **Large values** (money, timestamps): Rice-k ≈ FOR (≈23 bits) ≈ fixed width. Varints lose
  4–6 bits per value. For absolute large values, use FOR (column min + width) or Rice with a
  large k.
- **Per-chunk adaptive k** costs ≤0.1 bit/value against an oracle k for small and medium
  streams. That is the 4-bit header amortized. It loses 3 bits on `money_abs`, where the
  4-bit k range (≤15) is too small. Give k 5 bits, or use FOR mode, for wide columns.
- **The v5 attempt's class code** is 1.2–2.3× worse than EG-k on residuals. Its 4-bit
  class prefix costs more than the values do. Drop it.
- **Unity's bucket model** (Huffman-coded 16 power-of-two buckets, default table
  `{2,3,3,3,4,4,4,5,5,5,6,6,6,6,6,6}`; `StreamCompressionModel.cs` in
  `com.unity.collections` 2.7.1, verified) costs 2.8 bits on small residuals vs 2.1 for
  EG-0. Its fixed default table is not tuned to the data. Trained per field it does better
  (§6).
- **Group varint and Stream VByte** are SIMD formats ([Lemire et al.](https://arxiv.org/abs/1709.08990)).
  With no SIMD they lose on size (+2 bits/value of control) and on interpreted speed. Refuse them.
- **Simple-8b / PFOR**: no advantage over adaptive EG/Rice at these block sizes (25–400 values).

### 3.2 Decode cost in Luau (`luau/intcodes.luau`, verified round trip)

Values are mostly small (mean 1.4) or medium (mean 21). ns per value; the interpreted ranges
are over 3 runs.

| Code | Interpreted (client) | Native (server) | Notes |
|---|---|---|---|
| `readu8` / `readu16` (baseline) | 8.4–11 | 2.0–2.7 | |
| LEB128 | 12–20 | 2.4–4.8 | Fast because most values are one byte. Landscape's 81 ns was for multi-byte values |
| vu128 (one-byte fast path) | 12–27 | 2.3–5.5 | |
| PrefixVarint | 19–34 | 2.8–7.1 | Bit tests on the first byte cost more than LEB's compare in the interpreter |
| GroupVarint / StreamVByte | 28–57 | 6.4–15 | |
| FOR, fixed width, `readu32` window | 23–39 | 2.7–3.0 | `p // 8`, `p % 8` addressing, no state |
| FOR via `buffer.readbits` | 27–42 | 25–27 | Not a fastcall; never use it in native code |
| Exp-Golomb (`countrz`) | 58–81 | 11–17 | |
| **Exp-Golomb, 12-bit LUT** | **35–58** | 10.6–13.4 | Recommended client decoder |
| Rice (`countrz`) | 45–61 | 11–13 | |
| Class code (v5a) | 47–64 | 10.7–12.6 | |
| Unity bucket Huffman | 60–93 | 12–15 | |
| encode EG, inlined accumulator | 60–79 | **14–16** | Server path |
| encode LEB128 | 14–20 | 3.6–5.8 | |

**Per-frame cost.** A shooter60 frame is ≈230 coded values (29 entities × 8 fields) plus 116 flag bits.
- Client (interpreted): 230 × ≈45 ns ≈ 10 µs, plus prediction arithmetic, so **≈20–25 µs per
  frame on this desktop core**. At 60 Hz that is 0.15% of a core; a low-end phone might be
  3–5× slower (unverified multiplier).
- Server (native, encode): 100 recipients × 300 values × 15 ns ≈ **0.45 ms per tick**, before
  any sharing of identical sections between recipients.
- Searching all 16 k per column adds up to 16 cheap costing passes. That could double or
  triple the server figure (estimate, unmeasured) unless:
  - columns are costed once from a histogram of residual bit lengths;
  - or residual columns that are identical for several recipients are encoded once and shared.

Both are affordable. Byte varints would be 2–4× cheaper to decode and up to 1.3–2.4× larger on the wire.

---

## 4. Floats and spatial values

### 4.1 Representations (`sim_floats.py`)

| Magnitude (studs) | f32 step | f16 step | bf16 step |
|---|---|---|---|
| 10 | 9.5e-7 | 0.0078 | 0.0625 |
| 100 | 7.6e-6 | 0.0625 | 0.5 |
| 1000 | 6.1e-5 | 0.5 | 4 |
| 4000 | 2.4e-4 | 2 | 16 |
| 10000 | 9.8e-4 | 8 | 64 |

- **f16 and bf16 are wrong for world positions.** At 1000 studs f16 resolves 0.5 stud, and
  bf16 resolves 4. f16 is fine for bounded relative quantities: velocities at 100 studs/s
  resolve 0.06; local offsets; scales. bf16 has no use here.
- Use **fixed point** with an explicit range and step for positions. Bits = ⌈log2(range/step)⌉:
  - ±1024 studs at 1/32 stud = 16 bits;
  - ±4096 at 1/64 = 19 bits;
  - ±16384 at 1/16 = 19 bits.

  The error budget is half a step: 1/64 stud ≈ 4.4 mm, using Roblox's 1 stud ≈ 0.28 m (unverified convention).
- Roblox's own guidance quantizes misprediction thresholds at 0.1 stud under Server Authority
  (landscape §2.4). That is a useful ceiling: character positions at 1/32–1/64 stud are
  3–6× finer than the engine's own tolerance.

### 4.2 Lossless float coders vs quantization

Shooter, x/y/z per entity over time (`results/sim_floats.txt`):

| Coder | 60 Hz bits/value | 20 Hz bits/value |
|---|---|---|
| Gorilla (XOR vs previous, f32 adaptation) | 18.0 | 18.2 |
| Chimp (f32 adaptation) | 15.3 | 16.0 |
| ALP (decimal exponent + FOR per 1024-vector) | 27.3 (median e = 5) | 28.6 |
| **1/32-stud fixed point + guarded linear prediction + EG-0** | **2.02** | **3.34** |

**Why the lossless coders fail here.** Physics-produced floats have noisy low mantissa bits.
XOR coders win when consecutive values share their high bits *and* have zero low bits:
- [Gorilla](https://www.vldb.org/pvldb/vol8/p1816-teller.pdf) (VLDB 2015);
- [Chimp](https://www.vldb.org/pvldb/vol15/p3058-liakos.pdf) (VLDB 2022).

ALP, Elf, Camel and DeXOR exploit **decimal-origin** data, such as sensor readings with a
few decimals:
- [ALP](https://ir.cwi.nl/pub/33334/33334.pdf) (SIGMOD 2024);
- [Elf](https://www.vldb.org/pvldb/vol16/p1763-li.pdf) (VLDB 2023);
- [Camel](https://dl.acm.org/doi/pdf/10.1145/3698802) (2024);
- [DeXOR](https://arxiv.org/pdf/2601.00695) (2026 preprint).

Game positions are not decimal. ALP needed exponent 5 and 27 bits. An independent
evaluation found XOR-family coders slow and ALP the best all-rounder, *on database columns*
([Hishida et al., PVLDB 18(11) 2025](https://www.vldb.org/pvldb/vol18/p4396-hishida.pdf)).
Their premise does not hold for game state.

**Lossy is correct.** The receiver renders an interpolated value. An error of half a step is
invisible, while 1/32 stud of noise in the mantissa is pure entropy that costs bits.

**Raw floats** (a schema field with no range) should stay f32/f64 byte-aligned, since
nothing better exists for arbitrary values. The schema should steer users to ranges.

### 4.3 Prediction

Mean EG bits per position component at the best k (`sim_floats.py` part 3):

| Model | Hz | Baseline age | Delta | Linear (2b0 − b1) | Guarded linear (Unity) | Quadratic |
|---|---|---|---|---|---|---|
| shooter | 60 | 1 | 4.79 | **2.02** | 2.07 | 2.59 |
| shooter | 60 | 6 (100 ms) | 7.29 | **4.94** | 5.00 | 5.29 |
| shooter | 30 | 1 | 5.53 | **2.74** | 2.77 | 3.21 |
| shooter | 20 | 1 | 6.08 | **3.52** | 3.58 | 3.98 |
| racing | 60 | 1 | 9.73 | **4.91** | 4.94 | 5.54 |
| racing | 60 | 6 | 12.27 | 8.24 | 8.24 | **7.33** |
| mmo | 20 | 1 | 2.41 | 1.44 | **1.39** | 1.77 |

**How Unity's predictor works** (`GhostDeltaPredictor.cs`, com.unity.netcode 7.1.0, read from
the package). It predicts from the last three *acked* baselines, with tick-ratio weights in
1/16 units. It falls back to the newest baseline when the previous prediction
(`b1 + (b1 − b2)`) missed by at least the last delta:
```
predictBaseline = b1 + (b1-b2)*predictFrac/16
if |b0 - predictBaseline| >= |b0-b1| then return b0
return b0 + (b0-b1)*applyFrac/16
```
Unity applies it to quantized ints (floats quantized, 4-component quaternions), then codes
the residual with `WritePackedIntDelta` → the bucket model.

**Findings:**
- **Linear prediction halves the bits** at 20–60 Hz against plain delta.
- The guard costs ≤0.06 bit on steady motion. It wins on stop-and-go crowds (mmo) and
  protects against the large wrong extrapolations at turns, jumps and teleports.
- Quadratic helps only for long baselines on smooth high-speed motion (racing at 100 ms).
- **Use guarded linear prediction for every motion field: positions, smallest-three
  components, yaw.** Use "unchanged" for others.
- **On the unreliable lane**, prediction must use acked baselines. That costs 1.4–3.3 extra bits
  per component at 100 ms RTT. Sending a residual against the *previous sent* frame is
  unsound without acks.

**Dead reckoning on the receiver** (extrapolating for display) is a separate question, the
interpolation buffer. It does not change the wire. The codec's predictor must be
deterministic on both ends, so it must use integer quantized arithmetic exactly as written above.

### 4.4 Rotations

Monte Carlo over 20,000 uniform rotations:

| Scheme | Bits | Max error ° | Mean ° |
|---|---|---|---|
| smallest-three, 7 b/component | 23 | 1.78 | 0.68 |
| smallest-three, 8 | 26 | 0.90 | 0.34 |
| smallest-three, 9 (Gaffer) | 29 | 0.45 | 0.17 |
| smallest-three, 10 | 32 | 0.22 | 0.085 |
| smallest-three, 11 | 35 | 0.11 | 0.042 |
| smallest-three, 12 | 38 | 0.050 | 0.021 |
| smallest-three, 15 | 47 | 0.006 | 0.003 |
| naive 4 × 8 bits | 32 | 0.84 | 0.43 |
| naive 4 × 10 bits | 40 | 0.21 | 0.11 |
| yaw only, 8 / 10 / 12 / 16 bits | 8 / 10 / 12 / 16 | 0.70 / 0.18 / 0.044 / 0.003 | half of max |
| axis-aligned (24 rotations) | 5 | 0 | 0 |

- Smallest-three beats naive four-component quantization by 6–8 bits at equal error.
- Each extra bit per component halves the error.
- Error budgets in degrees:
  - **9 bits (29 total)** for characters and props;
  - **10–11 bits** for vehicles and cameras;
  - **yaw 10–12 bits** for upright characters. In the shooter model, 12-bit yaw dominates
    nothing.
- **Delta of smallest-three.** Gaffer found that 90% of orientations keep the same largest
  index 100 ms apart. Deltas on the three components then cost 80% of absolute
  ([snapshot compression](https://gafferongames.com/post/snapshot_compression/)). In the
  column coder, `qa/qb/qc` are ordinary residual columns, and an index change is just a large
  residual. The racing model includes this (`col_bits_pred` racing 124 B for 11 cars,
  rotations included).
- **Axis-aligned shortcut**: an `AlignedCFrame`-style 5-bit index, or 1 flag bit plus 5 bits
  inside a general rotation. Zap's 1-byte form wastes 3 bits.

### 4.5 Directions, CFrame, Color

- **Octahedral directions** ([Cigolle et al., JCGT 2014](https://jcgt.org/published/0003/02/01/)):
  - 8 bits per axis (16 total): max 0.93°;
  - 10 (20): 0.23°;
  - 12 (24): 0.057°;
  - 16 (32): 0.004°.

  These match the attempt's figures. Use **10–12 b/axis** for look vectors and hit normals.
- **CFrame** = position codec + rotation codec, coded as separate columns so each gets its
  own predictor and k. Building CFrames allocates on Roblox, so the decoder should produce
  `(vector, quaternion components)` and construct the CFrame once (skill reference).
- **Color3**: 3 × u8 is exactly Roblox's own `Color3uint8` storage, with max error
  0.5/255 ≈ 0.2% per channel. RGB565 errs by 1.6%, which is visible in gradients. Colors
  rarely change, so the column coder's "all zero" mode makes them nearly free when they stay
  the same.

### 4.6 Error budgets in the value's units (recommended defaults)

| Kind | Default | Error | Bits (absolute) | Typical residual bits at 60/20 Hz |
|---|---|---|---|---|
| Character position | ±1024–4096 studs, 1/32 stud | ±0.016 stud | 16–18 per axis | 2.0 / 3.5 |
| Vehicle position | ±4096, 1/64 | ±0.008 | 19 | 4.9 |
| Crowd/NPC position | ±8192, 1/16 | ±0.03 | 18 | 1.4 |
| Velocity | ±512 studs/s, 1/16 | ±0.03 | 14 | (column mode) |
| Rotation | smallest-three 9–10 b | ≤0.45° / 0.22° | 29 / 32 | ≈5–8 |
| Yaw | 10–12 b | ≤0.18° / 0.044° | 10–12 | ≈3–6 |
| Direction | oct 10–12 b/axis | ≤0.23° / 0.06° | 20–24 | n/a |
| Color | 3 × u8 | 0.2% | 24 | ≈0 when static |

---

## 5. Strings and dictionaries

`sim_strings.py`. Bytes per second of string data, `results/sim_strings.txt`.

| Strategy | Tycoon @10 Hz (5 min) | MMO names @20 Hz | Shooter kill feed @20 Hz |
|---|---|---|---|
| inline (len + bytes) | 179.7 | 18.5 | 80.9 |
| + engine zstd on the strings alone | 177.4 | 18.5 | 80.9 |
| + inside the frame (marginal) | 212.5 | 27.0 | 82.1 |
| static schema vocabulary (items, NPC names) | 172.4 | 8.4 | 83.4 |
| **intern, append-only (cap 4096)** | 101.3 | **4.5** | 67.4 |
| intern, LRU 64 slots | 160.0 | 4.5 | 77.0 |
| intern, append-only, chat marked transient | 102.2 | 4.5 | 67.4 |
| **template id + args (args interned)** | **27.6** | 6.7 | **9.6** |

**Findings:**
- **Zstd does nothing for per-frame strings.** Per-frame string sections are 10–40 B. Inside a
  byte-aligned frame, mixing text into binary literals *raised* the zstd cost slightly
  (212 vs 180).
- Landscape's static-vocabulary result (2.7× better than inline + zstd) holds for closed
  vocabularies such as the MMO names: static ids 8.4 vs inline 18.5.
- Dynamic content needs **per-connection interning**. Append-only beat LRU-64 for Zipf item
  names (101 vs 160 B/s), because LRU thrashed on the long tail. Unbounded tables are a memory
  and abuse risk, so cap them (4096) and stop interning when full.
- **Interning whole formatted strings pollutes the table.** The tycoon's
  "X upgraded to level N!" created 975 entries in 5 minutes. **Templates fix it**:
  `notify(template, item, level)` with the item interned and the level as a number costs
  27.6 B/s vs 101.
- That is a schema feature, not a codec. Encourage structured events over formatted
  strings, and offer a `format` helper on the receiving side.
- **Transient fields** (chat) should be marked non-internable. It barely changes bytes here,
  but it keeps unique strings out of the table.

**Eviction signalling.** On the reliable lane the receiver applies the same table operations
in the same order, so any deterministic policy (append-only, LRU, LFU) needs **no eviction
messages**. Both ends run the same algorithm. The cost is CPU and memory on both ends,
mirrored. Explicit eviction or "replace slot k" messages are needed only if the policy
depends on information the receiver lacks.

**Unreliable lane.** Interning there needs acked definitions:
- send the literal until the receiver acks the id;
- or route the first occurrence through the reliable lane.

Simplest rule: **unreliable frames may only reference ids the receiver has acknowledged.
Otherwise inline.**

**Interaction with zstd.** Interned ids are 1–2 bytes inside a bit section (EG-coded ids
cost ≈4–8 bits). Literal first occurrences go in the byte-aligned tail, where large bursts
(for example a joining client's catch-up of 500 names) get compressed by the engine for free.

---

## 6. Entropy coding

### 6.1 Size gain over the column coder and over zstd

`sim_entropy.py`. Tables are trained on a different-seed run of the same model. Bytes per
frame (`results/sim_entropy.txt`):

| Case | col_bits_pred | bucket Huffman | bucket rANS (ideal) | adaptive AC | symbol rANS | context rANS | dlt_col_varint + zstd | byte Huffman (Q3 style) |
|---|---|---|---|---|---|---|---|---|
| shooter60 (≈100 B) | 101.4 | 99.8 | 99.4 | 100.0 | 96.6 | 96.7 | 168.7 | 139.9 |
| racing60 | 123.6 | **116.9** | 119.7 | 120.2 | 135.5 | 136.0 | 201.3 | 160.7 |
| mmo20 (≈50 B, under threshold) | 50.3 | 60.1 | 47.5 | 47.6 | 47.2 | **45.1** | 120.4 | 75.5 |
| shooter100p@20 (≈560 B) | 560.3 | 572.8 | **546.8** | 550.2 | 582.6 | 582.9 | 744.0 | 722.6 |
| shooter60 unreliable | 149.7 | 150.4 | **147.3** | 148.2 | 162.9 | 163.3 | 227.8 | 193.8 |

**What the columns are:**
- bucket coders: Unity-style 16 buckets per field, raw offset bits;
- symbol rANS: a direct 0–62 alphabet plus escape;
- context rANS: 4 contexts from the previous field's residual magnitude (the x/z correlation);
- byte Huffman: Quake 3's design, one static Huffman table over frame bytes. `msg.c` seeds the
  tree with `msg_hData[256]` byte counts "from an actual game", Huffman-codes whole bytes, and
  writes the `bits & 7` remainder raw ([ioq3 msg.c](https://github.com/ioquake/ioq3/blob/main/code/qcommon/msg.c), read).

**Findings:**
- **Over the adaptive column coder, the best trained entropy coder per case gains 1.6–10%
  (10% is mmo context rANS); typically 2–6%.** Choosing the order per column per frame already captures most of
  the statistics.
- Static bucket Huffman is *worse* when zeros dominate (mmo 60 vs 50), because Huffman cannot
  spend less than 1 bit on a symbol.
- Direct-alphabet ANS is worse whenever residuals are wide (escape cost).
- **Over byte-aligned + zstd, the column coder already wins 25–58%**, at every frame size.
- Quake-style byte Huffman beats engine zstd on byte-aligned frames by 3–37% (shooter60:
  140 vs 169), but it still loses to the bit coder by 29–50%.

### 6.2 Luau cost (`luau/entropy.luau`, round trip verified)

2048 symbols, skewed byte alphabet.
- H0 = 1039 B; Huffman 1086 B (max length 12, LUT decode); rANS 1064 B.
- 12-bit probabilities, L = 2^23, byte renormalization ([Duda](https://arxiv.org/abs/1311.2540); Giesen's rans_byte layout).

| ns/symbol | Interpreted | Native |
|---|---|---|
| copy baseline | 19.8 | 5.7 |
| static Huffman decode | 46.3 | 19.1 |
| static Huffman encode | 42.1 | 15.8 |
| static rANS decode | **105.6** | 25.2 |
| static rANS encode | 87.7 | 26.0 |

### 6.3 Verdicts

| Coder | Verdict | Why |
|---|---|---|
| Adaptive per-column EG/Rice (k per column per frame) | **Core** | Captures most of the entropy-coding gain at ≈35–60 ns per value interpreted, with no tables, training or versioning |
| Static Huffman, tables trained offline (Quake 3) | **Refuse** for state; optional plugin for byte payloads at most | ≤5.4% over the column coder, and worse when zeros dominate. Tables must be versioned with the schema and shipped to clients. 46 ns/symbol |
| Static rANS / tANS with trained per-field tables | **Optional plugin**, off by default | Best ideal gain was 2–10%, but 106 ns/symbol interpreted is about 2–3× the EG decode, and it needs a trained-table artifact keyed by the schema hash. Only worth it for a game whose bandwidth is dominated by one large stream |
| Adaptive arithmetic / range coding | **Refuse** | Gain equals static ANS here (≈1–5%). Per-symbol model updates in the interpreter. Only sound on ordered lanes with shared adaptive state |
| Unity's bucketed model as is (fixed default table) | **Refuse** as is | 2.8 vs 2.1 bits on small residuals. Per-column adaptive EG is the same idea without a table |
| Context mixing / learned models | **Refuse** | See §7 |

Landscape listed rANS for sub-100 B unreliable packets. With a bit-packed layout those
packets are already near entropy (mmo 50 B vs 45–47 ideal), so the plugin case is weaker than
landscape assumed.

---

## 7. Research 2023–2026 and its applicability

Searched: lossless float compression 2023–2026; lightweight integer compression; snapshot
compression in games; learned compression; format-aware compression. I found no academic
work on game-snapshot compression after Gaffer and Unity Netcode, and no 2024–2025 game
networking papers turned up in DevForum, arXiv or general search. One 2025 thesis on voxel
sync uses delta + DEFLATE ([Oulu](https://oulurepo.oulu.fi/handle/10024/54736)).

| Work | What it does | Applicable? |
|---|---|---|
| ALP (Afroozeh, Kuffó, Boncz, [SIGMOD 2024](https://ir.cwi.nl/pub/33334/33334.pdf)); DuckDB's default float codec | Finds a decimal exponent per vector so doubles become integers, then FOR-packs them. ALP_RD splits the front bits for "real" doubles | **No.** Positions are not decimal: 27 bits/value (§4.2). Its lesson, *convert to integers then use integer coding*, is exactly quantization |
| Elf / Elf+ ([VLDB 2023](https://www.vldb.org/pvldb/vol16/p1763-li.pdf)), Camel ([2024](https://dl.acm.org/doi/pdf/10.1145/3698802)), DeXOR ([arXiv 2601.00695](https://arxiv.org/pdf/2601.00695), 2026) | XOR coders that erase or realign decimal significance | No, for the same reason. They are also bit-serial and slow (Hishida et al.) |
| Evaluation: Hishida et al. ([PVLDB 18(11), 2025](https://www.vldb.org/pvldb/vol18/p4396-hishida.pdf)) | Compares 10+ float codecs and finds no single winner. ALP and Zstd rank high on ratio; XOR coders are slow | It confirms that general-purpose zstd is hard to beat *on long columns*. Our frames are short, which is why bit codes win |
| Pcodec (Loncaric et al., [arXiv 2502.06112](https://arxiv.org/pdf/2502.06112), 2025) | Mode split into latent variables, delta, then near-entropy binning ("bins" of value ranges with ANS). Reports 29–94% better ratio than other numerical codecs | **Partly.** Its bins are Unity's buckets with trained, data-specific boundaries and ANS. At ≈100 values per frame, the bin table overhead dominates. The idea is to choose bucket boundaries per column offline. Gain ≤10% (§6) |
| LeCo (Liu, Zeng, Zhang, [SIGMOD 2024](https://arxiv.org/pdf/2306.15374)) | Fits a learned regression per segment and stores residuals; FOR, Delta and RLE are special cases | **Yes, in its simplest form.** Guarded linear prediction is a 2-point "learned" model per entity. Higher-order fits lost (§4.3, quadratic) |
| FastLanes (Afroozeh & Boncz, VLDB 2023) **[MEMORY]**; Stream VByte ([Lemire et al. 2018](https://arxiv.org/abs/1709.08990)) | Data layouts for SIMD bit-unpacking | No SIMD in Luau. Its transposed layouts do not help a scalar interpreter |
| OpenZL (Meta, [blog 2025-10-06](https://engineering.fb.com/2025/10/06/developer-tools/openzl-open-source-format-aware-compression-framework), arXiv 2510.03203) | Format-aware compression: a schema describes the data; a trained "plan" of transforms (column split, delta, tokenize) feeds entropy coders; one universal decoder | **The right philosophy, at a smaller scale.** Lync's schema already knows the structure, so the codec *is* the plan. Meta's stated motivation: generic compressors "leave compression gains on the table" for columnar, enum-based, range-restricted data. That matches §2. The framework itself (C, large) does not fit |
| Centrifugo real-time experiment ([2024](https://centrifugal.dev/blog/2024/05/30/real-time-data-compression-experiments)) | Delta vs deflate on a simulated football match: Protobuf + delta = 4382 B; adding deflate raised it to 4473 B | Independent evidence that general compression on top of compact binary deltas does not help |
| Learned or adaptive coders small enough for an interpreter | JPEG-LS-style adaptive Golomb (k from a running mean per context; [Weinberger et al. 2000](https://doi.org/10.1109/83.855427)) **[MEMORY]**; adaptive binary range coders (LZMA-style) | Adaptive Golomb **yes**: a running-mean k per column can replace the 4-bit header on the reliable lane (both ends see the same history). That saves ≤0.1 bit/value, so it is optional. Binary range coders cost ≥1 multiply per *bit*: refuse |
| Neural / context-mixing compressors (2023–2026 LLM-based compression) | — | Refuse: orders of magnitude over the interpreter budget |

**Honest summary.** For game state, the state of the art is still Gaffer (2015) and Unity
Netcode: quantize, predict against baselines, code the residuals with small adaptive codes.
The 2023–2026 database literature confirms the transform-first structure, but its codecs
target long decimal columns. Nothing newer beats per-column adaptive EG by more than about
10% at these frame sizes.

---

## 8. Corrections to earlier briefs

- **Landscape §2.2 "byte-aligned delta + engine zstd ≈ hand bit-packed delta (191 vs 177 B)".**
  It holds against a naive bit-packed delta. Against a **column-adaptive** bit coder with
  prediction, byte-aligned + zstd is 1.3–2.4× larger in every model but the tycoon, where they tie (§2.1).
  Landscape's rule "keep bulk payloads byte-aligned" is **wrong for state**. It stays right for
  strings and user blobs.
- **Landscape §4 "LEB128 read ~81 ns interpreted".** That was for 2–3-byte values. Mostly
  one-byte values cost 12–20 ns.
- **v5-attempt class code**: replace it with EG-k/Rice-k. It is 1.2–2.3× larger (§3.1).
- **v5-attempt column coder (PACKED/RUNS/DELTA/STATE)**: confirmed in spirit
  (`col_bits_adapt`). Add prediction, and FOR mode for wide absolute columns.

---

## Implications

**Recommended encoding per value kind**:

| Value kind | Encoding | Support |
|---|---|---|
| Replicated state | One bit-packed frame section in column order. Per column a 2-bit mode (zero / EG-k / sparse / raw-or-FOR) and k (4–5 bits) chosen per frame. Residuals against guarded linear prediction for motion fields, against the baseline otherwise | §2.1, §2.3, §4.3 |
| Baselines | Reliable lane: the previous frame (no acks). Unreliable lane: the last acked frame (+13–47% bits at 100 ms) | §2.1, §1.3 |
| Positions | Fixed point with schema range and step: default 1/32 stud for characters, 1/64 for vehicles, 1/16 for crowds. Never f16/bf16 for world positions | §4.1, §4.6 |
| Rotations | Smallest-three, 9 b/component by default (0.45°), 10–11 for vehicles. Yaw-only 10–12 bits. Axis-aligned 5-bit index | §4.4 |
| Directions | Octahedral, 10–12 b/axis | §4.5 |
| Color | 3 × u8 | §4.5 |
| Velocities and local offsets | Fixed point; f16 allowed | §4.1 |
| Unbounded integers | Zigzag + EG/Rice in the bit section. LEB128 only in byte-aligned user payloads and headers that must be parsed without the bit reader | §3.1 |
| Large counters (money, timestamps) | FOR or Rice with a large k. Delta when they change slowly | §3.1 |
| Strings | Static schema vocabularies → ids. Dynamic strings → append-only per-connection intern table on the reliable lane (cap 4096, no eviction messages). Formatted messages → templates. Literals go in a byte-aligned tail | §5 |

**By frame size:**
- **Every size:** the same bit-packed frame, with a byte-aligned tail for literals and user
  bytes, in one buffer argument.
- **Over 100 B:** do not branch on the threshold. The engine cannot shrink the bit section
  and compresses the tail for free.

**Core:**
- the bit reader and writer with the LUT EG decoder;
- the column coder with prediction;
- quantization types (fixed point, smallest-three, octahedral, yaw, axis-aligned);
- intern tables and templates;
- exact pre-send frame sizing for unreliable batching.

**Optional plugins:**
- trained rANS per field, for single-stream-dominated games (≤10%);
- running-mean adaptive k;
- byte-plane-split catch-up keyframes;
- a PacketProfiler size estimator that knows frames are incompressible.

**Refuse:**
- relying on engine zstd for state;
- Warp-style XOR deltas;
- f16/bf16 positions;
- lossless float coders (Gorilla/Chimp/ALP/Elf);
- group varint and Stream VByte;
- the v5 class code;
- static Huffman;
- adaptive arithmetic coding;
- LZ in Luau;
- learned coders.

**Unknown until the Studio probe runs**, with the decision each one gates:
- **Cross-frame/cross-call context (T5).** If it exists, re-evaluate byte-aligned absolute
  layouts. This is the only result that could overturn §2. Current evidence says no (§1.1).
- **Raw fallback (T2).** If there is none, bit frames of 100 B or more pay +9–13 B. Consider
  splitting into two arguments under the threshold, but only if T4 shows per-argument compression.
- **Threshold (T2, T6) and level (T3).** These matter only for the byte-aligned tail and the
  catch-up keyframes. They set the size model PacketProfiler-style tools should use.
- **Unreliable limit accounting (T7)** and the exact random-buffer ceiling. These set Lync's
  unreliable batch bound (1000 B minus measured overhead).
- **Strings compressed? (T4)** This decides whether long user strings should be sent as
  buffers to get compression.
