# Inbound bound, re-measured on every shape it must cover

2026-10-15. Prover unit. Re-measures the inputs of `design/v5.md` §7.5's inbound CPU bound after
`reviews/v5-3.6-runtime.md` findings 2–7, on the milestone build's receive path (`f1fbfd7:src`, exported outside the
repo by `run.sh`) and on a generated decoder (`gen.luau`, which writes one module per definition into the work
directory). Inputs read: `probes/inbound-budgets/` (RESULTS.md and probes), `probes/review-3.6-runtime/`
(`probe.luau`, `probe2.luau`, `shape.luau`, `acc.py`).

## Checklist

The claims are stated in the terms of the restructured §7.5 (decode units; the coordinator's correction, mid-unit).
Each element costs w = ⌈p(L) / 100 ns⌉ units, with p(L) = p_0 + p_1 × L over that element's own leaves. Arrays and
maps weigh 2, a union's tag 1, an optional's presence 1, `t.vector3`, `t.color3` and `t.vector3f32` 3, `t.direction`
2, `t.rotation` 4 and `t.cframe` 7. One frame costs at most (1 + μ) × (c_f + c_b × its charge + 100 ns × its units).

- [x] 1. A per-leaf cost model over every codec shape (scalars, strings, buffers, arrays, maps, optionals, unions,
      records, nested), stated as p(shape) with its fit and largest residual over every measured case. Also:
      whether 100 ns per unit, at p_0 = 2,000 ns and p_1 = 133 ns with the weights above, is an upper bound over
      every shape, and the worst residual (milestone and generated decoders, native and interpreted).
- [x] 2. c_f and c_b per lane with every candidate hashed and every accepted position (reliable e … e + 4, and
      each of the 3 unreliable extensions). Also the instance-list walk per entry (now in step 2) and the untagged
      `HELLO` path (now never hashed, and decoded under the unit charge).
- [x] 3. The bound with these inputs, its worst case at the current defaults, and the defaults that meet 2 ms/s
      per player native at μ = 0, 0.10 and 0.25 (one marked chosen).
- [x] 4. The §9 CI gate: a test that fails when any shape exceeds the bound, and the shapes it must include. It is
      shown failing on draft 3.6's per-element bound and run against the new one.

**Host and tools.** The CLI VM only: Luau 0.742 built from `.data/projects/luau` (Release). `luau -O2` is the
interpreted mode (Roblox clients, and server modules not marked native); `luau -O2 --codegen` is the native mode (a
Roblox server script marked `--!native`). Python 3.13.16 runs `derive.py` (stdlib only). The host is an Intel Xeon
2.1 GHz with 4 cores, shared. **CLI timings do not transfer exactly to Roblox.** No figure includes engine costs:
remote dispatch, the engine's receive path, or the `task.spawn` of handlers. Roblox's native code generator and GC
differ from the CLI's. The Roblox datatypes are stand-ins (`rbx.luau`):
- `Vector3` is the native `vector`, as on Roblox.
- `CFrame` and `Color3` are Luau tables. On Roblox they are C++ userdata, so the CFrame construction inside
  `t.rotation`'s and `t.cframe`'s canonical check costs differently there.
- `Instance` and `EnumItem` are tables.

**Method.** `sh run.sh BUILD_DIR WORK_DIR` exports `f1fbfd7:src` twice into WORK_DIR, never into the repo. Its header
lists every patch to those copies. The timed copy exposes four locals and does not change behaviour. It binds
`Vector3.new` to `vector.create` and CFrame/Color3 to the stand-ins. Its instance check reads `"table"` for
`"Instance"`, which keeps the same builtin and compare per entry. The builder copy sees typeof stand-ins so that the
milestone's own encoder accepts Roblox-typed values.

Steps:
1. `build_frames.luau` encodes every frame of the shape set with the milestone's encoder (`Run.encode`, `Frame.up`).
2. `gen.luau` writes the generated decoder.
3. `decode_cost.luau` (claim 1) and `tag_cost.luau` (claim 2) time every frame through `Inbound.receive`, a milestone
   server runtime assembled in the probe with no listeners and buckets unlimited for timing. Each case gets a
   warm-up, then 7 rounds, with a full GC before each timed block.
4. Runs: 3 interpreted and 7 native per probe (`run.sh` steps `decode`, `tag`, `extra`).
5. `derive.py` reads the outputs into `derive.out`. Each figure is the median of the run medians, and [brackets]
   give the highest run median, which is the spread a margin has to cover. Within-run spread is ±5–30% on this
   shared host. A tiny frame's single-run median can sit 50% above the median of runs.

The generated decoder is checked against the milestone's on every frame it times: equal values, message count and
element count. Its form is straight-line reads at an upvalue cursor, constants inlined, one table constructor per
record and no kind dispatch. The column reader is ported from `wire/column.luau`, and the milestone's leaf math is
reused. It is timed as "generated path" = F_e4 − D + G, so the tag, buckets and step 5 stay the milestone's. All
decoding runs in each definition's own module, because a single 33,000-line module was not compiled natively by
the CLI: its native and interpreted G were equal.

**The shape set** (`shapes.luau`, 319 frames plus the claim-2 frames). Each codec kind is a record of 1 and of 16
fields, in four forms:
- one message alone in a frame (row1);
- one-message runs alternating between two definitions (runs);
- one run of constant values (colC, column mode 0);
- one run of random values (colR, column modes 1–3).

The frames fill 16,382 B or 512 messages. The kinds:
- scalars: `t.bool`, `t.int(0,255)`, `t.int(0,2^32−1)`, `t.int()` (varint), `t.number`, `t.f32`, `t.f64`, `t.angle`,
  `t.enum` of 3, a 16-item Roblox enum, `t.instance("BasePart")`;
- strings and buffers of 8 and 200 B;
- `t.vector3`, `t.vector3f32`, `t.direction(16)`, `t.rotation(12)`, `t.cframe`, `t.color3`;
- optionals, present and absent, and an optional record;
- nested records (1 and 4 deep);
- a 2-variant union;
- arrays of 0, 1 and 4 elements, arrays of records, and arrays of empty arrays;
- maps of 0, 1 and 4 pairs, int- and string-keyed;
- the review's 64 empty arrays and 32 empty maps per message;
- 128-bool records (constant and random);
- the busy model's `move6` and `sm`;
- a mixed record with every node kind;
- 4,096-element arrays;
- one 15,900 B string and one 15,900 B buffer.

`t.custom` and `t.convert` are not in the set: their decode is game code.

## Results

### 1. A per-leaf cost model over every codec shape — **false that 100 ns per unit holds with §7.5's p_0 and weights; true (within 2% of the medians, 0.94 generated) with the measured weights below**

Probe: `decode_cost.luau` over `frames_data` (built by `build_frames.luau`) with `gen.luau`'s decoder. Output is
in `decode_cost.out`, aggregated in `derive.out`: the "per frame" table, "marginal", "variant M" and "the rule as
§7.5 states it". Each frame is judged at e + 4, the costliest accepted position. The test is whether
F_e4 ≤ c_f,r + c_b,r × B + 100 ns × units, with c_f,r = 3,938 ns and c_b,r = 23.04 ns/B from claim 2.

**The rule as §7.5 states it is not an upper bound.** These are the median of 7 native runs, milestone decoder,
whole frame F_e4 / bound, with the generated path in parentheses:

| Frame | F_e4 / bound | Why |
|---|---|---|
| recordDeep4_16 runs (16 fields of `{a={a={a={a=int}}}}`) | **2.55** (1.14) | nested records weigh 0, measured 152 ns each |
| recordDeep4_16 row1 | 1.91 (1.08) | same |
| cframe_16 colR | 1.47 (1.33) | `t.cframe` weighs 7 (931 ns), measured 1,762 ns |
| rotation_16 colR | 1.46 (1.40) | `t.rotation` weighs 4 (532 ns), measured 1,000 ns |
| robloxEnum_16 runs | 1.32 (0.82) | weight 1 (133 ns), measured 343 ns |
| instance_16 runs | 1.25 (0.74) | weight 1, measured 266 ns |

36 of 319 frames are over (milestone), 12 by more than 25%; generated, 9 are over. The worst excess per unit is
2.87 × 100 ns (recordDeep4_16 row1). The review's two shapes are now inside: 64 empty arrays (0.38–0.63) and
32 empty maps (0.25–0.62).

**The model (variant M), from marginal costs.** Per node kind, the cost per field per message is
((F_e − h·B)/msgs at 16 fields − the same at 1 field) / 15, with h = 4.35 ns/B for one hash. The value used is the
largest over the four forms and both decoders. Native ns per node:

| bool | int | varint | number | f32 | f64 | angle | enum | string | buffer | Roblox enum | instance |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 117 | 144 | 271 | 154 | 214 | 269 | 144 | 115 | 308 | 306 | 343 | 266 |

| vector3 | vector3f32 | color3 | direction | rotation | cframe | optional | union tag | array | map | nested record |
|---|---|---|---|---|---|---|---|---|---|---|
| 341 | 411 | 396 | 402 | 1,000 | 1,762 | 112 | 263 | 177 | 158 | 152 |

The base cost of a message:
- with data, in its own frame: 1.7 µs median over kinds, 2.5 µs largest (the 1-field record less its field);
- in one-message runs: 1.15 µs median, 1.56 µs largest;
- in columns: 0.48–0.80 µs;
- with no payload: 1,286 ns (row1), 821 ns (runs), 410–615 ns (columns);
- an array element or map pair beyond its nodes: 50 ns.

The generated decoder is cheaper per node in most kinds, for example int 101, bool 106, a nested 1-field record 123
and a union field 212 ns. Its message base is 246–468 ns with no payload. It is not cheaper in kinds that call the milestone's leaf math:
rotation 969 ns and cframe 1,595 ns. `derive.out` has every form.

So p(shape) = 2,500 ns + Σ_nodes w_kind, with each node of the element counted once outside its nested elements.
As a unit rule at p_1 = 133 ns:
- p_0 = **2,500** ns (2,000 in §7.5);
- leaf weights (§7.5's → measured): int 1 → **2**, varint 1 → **3**, number 1 → **2**, f32 1 → **2**,
  f64 1 → **3**, angle 1 → **2**, string 1 → **3**, buffer 1 → **3**, Roblox enum 1 → **3**, instance 1 → **3**,
  `t.vector3f32` 3 → **4**, `t.direction` 2 → **4**, `t.rotation` 4 → **8**, `t.cframe` 7 → **14**,
  union tag 1 → **2**, **nested record 0 → 2**;
- unchanged: bool 1, enum 1, `t.vector3` 3, `t.color3` 3, optional 1, array 2, map 2.

**Fit and residual.** Under that rule, the largest whole-frame F_e4 / bound over the 319 frames is:
- median of 7 runs, milestone: **1.020** (int8_1 row1), then f32_1 row1 at 1.003, with every other frame ≤ 0.98;
- generated path: **0.942**;
- worst single run: 1.568. 54 frames are over in some single run, 34 at 1.10 and 18 at 1.25.

The rule is loose where many elements share a frame: for example, columns are 0.25–0.6 of their bound and long
arrays 0.01–0.12. A linear-programming upper fit over the same frames (variant A in `derive.out`) is a cross-check:
p_0 2,500, max 0.982. Its individual weights are not unique (int 6, f32 7), so the marginal model is the one stated.
A variant with a per-frame term folded into c_f (B) needs 2.0 µs more c_f per frame. It leaves fewer units at every
μ, so it is not proposed.

**Interpreted** (3 runs). Per node, cost is 1.5–2.5× native for most kinds, for example int 1.5 × 133, rotation
21 × 133 and buffer of 200 B 30 × 133. The native unit rule, priced at interpreted c_f,r 11.8 µs and c_b,r
163 ns/B, needs up to 197 ns per unit (2×). The exception is the 15,900 B string at e + 4, where the interpreted
c_b,r from `tag_cost` falls 3% short of `decode_cost`'s and leaves 65 µs over one element. Interpreted servers stay
outside the bound, as §7.5 states.

Tool: Luau 0.742 (`luau -O2`, `luau -O2 --codegen`), `f1fbfd7:src`, 3 interpreted and 7 native runs; Python 3.13.16
(`derive.py`).

### 2. c_f and c_b per lane at every position, the walk, and the untagged path — **measured; c_f,r 3.94 µs and c_b,r 23.0 ns/B (true to §7.5's 3.76 and 23.75 within 5%); c_f,u 3.34 µs against §7.5's 2.9 (false, 15% over); walk 5.2 ns per entry; untagged `HELLO` rows inside the unit charge**

Probe: `tag_cost.luau`. Output is in `tag_cost.out`, aggregated in `derive.out` ("claim 2"). No key is pending in
any state. §4.5 now hashes at most 5 and 3 times; the milestone hashes twice that with a pending key, as measured
in `probes/inbound-budgets` claim 2. The unreliable window's newest is 10,000, so all three extensions are hashed.

Native ns per frame, median of 7 runs [highest run median]:

| Frame | e | e+1 | e+2 | e+3 | e+4 | failing (5 hashes) |
|---|---|---|---|---|---|---|
| reliable header only, 3 B | 2,196 | 3,282 | 3,518 | 3,688 | **3,938** [4,280] | 2,759 |
| reliable string, 1,030 B | 9,344 | 14,594 | 18,666 | 22,966 | 26,814 | 24,864 |
| reliable string, 15,906 B | 79,923 | 143,934 | 210,887 | 278,705 | 347,743 | 348,722 |
| reliable buffer, 1,030 B | 8,750 | 14,939 | 18,952 | 24,729 | **29,134** | 24,249 |
| reliable buffer, 15,906 B | 83,609 | 153,723 | 214,238 | 289,042 | 359,631 | 355,800 |

| Frame | 1st extension (1 hash, accepted) | 2nd (2 hashes, replayed) | 3rd (3, accepted) | failing (3) |
|---|---|---|---|---|
| unreliable header only, 4 B | 2,620 | 2,274 | **3,338** [4,954] | 3,056 |
| unreliable string, 962 B | 8,757 | 10,663 | **17,642** | 15,154 |

The prices:
- **c_f,r = 3,938 ns** [4,280]: the header-only frame at e + 4.
- **c_b,r = 22.39 ns/B** [29.09] before the walk; with the walk **23.04 ns/B** [29.99]. It is the costliest
  (F − c_f,r − one element's units) / (B − 3) over frames of 1 KB or more. The 1,030 B buffer at e + 4 sets it; the
  15,906 B string at e + 4 gives 21.5.
- **c_f,u = 3,338 ns** [4,954]: the header-only frame accepted at the third extension.
- **c_b,u = 12.63 ns/B** [18.47]; with the walk **13.28** [19.36]. The 962 B frame at the third extension sets it.

Interpreted:
- c_f,r 11,782 ns and c_b,r 162.88 ns/B, with the walk;
- c_f,u 10,818 ns and c_b,u 137.46 ns/B.

**The instance-list walk** (`Inbound._instanceCountOf`, the milestone's step-1 loop, 0–16,384 entries) costs
**5.19 ns per entry native** [7.19], or 0.65 ns per byte of charge at 8 B per entry. Interpreted it is 39.4 ns per
entry. In the milestone the walk runs before any budget, so:
- 16,384 entries cost 87–91 µs per call refused at the byte bucket, on either lane;
- a frame refused at the frame bucket, with no list, costs 839 ns (unreliable);
- reliable frames refused at a bucket cost 2.0 µs, because the milestone hashes them. §6.1 no longer hashes them.

The restructured §6.1 stops the walk at the byte bucket's tokens. That bounds one call at tokens / 8 entries:
6,144 entries, about 32 µs native, at the 49,152 B reliable burst. A refused call takes no tokens, though, so each
refused call can walk that far again. At the engine's documented ~500 calls a second per client per remote type
(`[client-security §2.1]`), that is about 16 ms/s per lane outside the bound (derived). The bound covers it if a
refused frame is charged the bytes it walked, or if the walk is capped well below the tokens.

**Untagged `HELLO`** (frames of 1, 64 and 867 rows, the last 16,369 B). Native ns per row at 867 rows:
- `Handshake.untagged` decode alone: 470 (valid), 508 (not canonical);
- the milestone's receive of a non-canonical untagged frame before any tagged one: 905. That is the decode, then
  5 failing hashes, 785 µs per frame;
- the same frame once tagged: 402;
- a valid untagged frame, every `HELLO` handled: 1,419;
- `HELLO` rows in a tagged frame at e + 4: 1,806.

Against c_f,r + c_b,r × B + 100 ns × 27 units per row (L = 5 at §7.5's weights), every one of these is at most
**0.83** of its bound, and the decode alone at most 0.23. Under the measured weights a row has L = 4 × 2 + 3 = 11,
which gives 40 units, so it fits too. The design's untagged path (not hashed, decoded under the unit charge) is
therefore inside the bound. Two notes on the milestone, from reading the code (not measured): it decodes untagged
frames before the tag check, and it hashes them when they fail. `Handshake.hello` also keeps each new namespace name
in `conn.hashByName` and `conn.waiting` until its 10 s answer.

Tool: Luau 0.742, `f1fbfd7:src`, 3 interpreted and 7 native runs; Python 3.13.16.

### 3. The bound, the current defaults, and defaults for 2 ms/s at each margin — **derived: at the current defaults the bound is 2,043 µs/s at μ = 0 with the measured weights (2% over 2 ms/s) and 3,918 µs/s with §7.5's weights as stated; μ = 0.25 chosen, `inbound.elements.perSecond` 5,000 units/s**

Probe: `derive.py` ("claim 3"). It uses native prices: c_f,r 3,938 ns, c_f,u 3,338 ns, c_b,r 23.04 ns/B and
c_b,u 13.28 ns/B (the walk included), and 100 ns per unit at the measured rule of claim 1 (p_0 2,500, weights
above).

Per player and second:

  CPU ≤ (1 + μ) × (3.94 µs·Fr + 3.34 µs·Fu + 23.0 ns·Br + 13.3 ns·Bu + 100 ns·E)

At the current defaults (Fr 60, Fu 120, Br 8,192, Bu 16,384, E 10,000 units/s), frames take 637 µs, bytes 406 µs and
units 1,000 µs, for **2,043 µs/s at μ = 0**. That is 2,554 µs/s at μ = 0.25. With §7.5's weights as stated, units
cost up to 2.87 × 100 ns (claim 1), so the same defaults reach **3,918 µs/s**. The busy model costs 2,690 units/s at
the measured rule (60 `move6` at 39 units and 10 `sm` at 35), against 1,940 at §7.5's.

Defaults that meet 2 ms/s native by §7.5's own rule: E = ⌊(2,000 µs / (1 + μ) − frames − bytes) / 100 ns⌋, rounded
down to a multiple of 1,000. The frame and byte budgets are unchanged.

| μ | `inbound.elements.perSecond` | room over the busy model | bound at these defaults | full refill (240, 240, 49,152 B, 32,768 B, 81,920 units) |
|---|---|---|---|---|
| 0 | 9,000 units/s | 3.3× | 1,943 µs/s | 11.5 ms |
| 0.10 | 7,000 units/s | 2.6× | 1,918 µs/s | 12.7 ms |
| **0.25 (chosen)** | **5,000 units/s** | **1.9×** | **1,929 µs/s** | **14.4 ms** |

Why 0.25:
- The medians already need 2%: the largest median-run ratio is 1.020.
- In the gate's three runs of the measured rule (claim 4, `gate.out`), the highest shape ratio at μ = 0 was
  1.04–1.26. At μ = 0.10, 0–5 shapes were over per run. At μ = 0.25, 0 or 1 shape was over, the one being the
  unreliable header-only frame at the third extension, whose price c_f,u spreads 3.34 [4.95] µs.

What would change the choice:
- If c_f,u is priced at its highest run median (4.95 µs), that shape fits at μ = 0.25 (derived limit 1.74 against
  1.26 measured). The frame term then rises by 0.19 ms/s, which leaves 3,000 units/s at μ = 0.25.
- A quieter reference host would allow μ = 0.10.

Consequences elsewhere in §7.5:
- A no-payload element now costs 25 units, not 20, so the unit burst's "81,920 = 4,096 elements of no payload"
  becomes 102,400.
- The busy model's 1,950 units become 2,690.

Tool: Python 3.13.16 (`derive.py`), over the Luau 0.742 native runs.

### 4. The §9 CI gate — **true that a ratio gate catches the bound's failures: it fails on draft 3.6's bound (110 of 331 shapes over) and passes the measured rule at μ = 0.25 in 2 of 3 runs; the third flaps on one shape (1.259 against 1.25)**

Probe: `gate.luau`. `run.sh` step `gate` runs `v36` once and `new` three times; output is in `gate.out`. One gate run
is 3 sweeps of every shape, each timed once. Each sweep's denominator is the median of the header-only reliable frame
at e + 4, timed before every 32nd shape. Each shape's ratio is the median over the sweeps. The gate compares that
ratio with (1 + μ) × (c_f + c_b × charge + 100 ns × units) / H_REF and **raises (nonzero exit) when any shape is
over**, listing every failing shape.

H_REF is the gate's own header-only frame on the reference host: 3,590 ns. `tag_cost`'s harness gives 3,938 ns for
the same frame. Four earlier gate runs that used 3,938 ns as the denominator (not kept) gave ratios about 9% higher,
so a gate has to calibrate H_REF with its own harness.

The shapes it must include, all 331 in `gate.luau`:
- header-only frames at e and e + 4;
- failing tags on both lanes with every candidate hashed (3 B, 1 KB and 16 KB reliable; 4 B and 962 B unreliable);
- the unreliable third extension;
- every frame of claim 1's shape set at e + 4, which covers:
  - every codec kind in all four forms, in records of 1 and 16 fields and of 128 bools;
  - records of empty arrays and maps, in row and column form;
  - unions, nested records and the mixed record;
  - 4,096-element arrays;
  - the 15,900 B string and buffer;
- untagged `HELLO` frames, canonical and not;
- instance lists of 4,096 and 16,384 entries, refused at the byte bucket.

| Run | Bound | Shapes over | Highest ratio / bound at μ = 0 | Over at μ 0 / 0.10 / 0.25 | Exit |
|---|---|---|---|---|---|
| 1 | v36 (2.53 µs, 20.2 ns/B; 2,000 + 133 L per element, arrays, maps and unions 0) | **110** | 3.92 (arr64empty runs) | 110 / 83 / 50 | **1** |
| 2 | new, μ = 0.25 | 0 | 1.080 (map32empty row1) | 3 / 0 / 0 | 0 |
| 3 | new, μ = 0.25 | **1** (unreliable third extension, 4 B: 1.259) | 1.259 | 8 / 5 / 1 | **1** |
| 4 | new, μ = 0.25 | 0 | 1.043 (arr0_1 row1) | 2 / 0 / 0 | 0 |

The failure case is shown: the gate rejects draft 3.6's bound on 110 shapes, including the header-only frame at
e + 4 and the review's arrays at 3.9×. On the measured rule it passes two runs in three at μ = 0.25. The third fails
on the noisiest price (c_f,u), not on a decode shape. A gate that is not to flap on this host needs one of these:
c_f,u at its highest run median (claim 3), more sweeps, or a quieter reference host.

Tool: Luau 0.742 (`luau -O2 --codegen`), `f1fbfd7:src`.

## Summary

| Claim | Verdict | Decisive figure |
|---|---|---|
| 1. Cost model, unit price | **false** with §7.5's p_0 and weights; **true within 2%** with the measured ones | stated rule: 36 of 319 frames over, nested records 2.55×, rotation 1.46×, cframe 1.47×; measured rule (p_0 2,500; nested record 2, rotation 8, cframe 14, …): max 1.020 milestone, 0.942 generated |
| 2. c_f, c_b, walk, `HELLO` | measured | c_f,r 3,938 ns at e + 4, c_b,r 23.04 ns/B, c_f,u 3,338 ns at the third extension (§7.5: 2.9 µs), c_b,u 13.28 ns/B; walk 5.19 ns per entry (refused calls walk unpaid); `HELLO` rows ≤ 0.83 of the bound |
| 3. Bound and defaults | derived | current defaults 2,043 µs/s at μ = 0 (3,918 with §7.5's weights); E = 9,000 / 7,000 / **5,000 (μ = 0.25, chosen)** units/s |
| 4. CI gate | true that it gates | fails draft 3.6 on 110 shapes; passes the measured rule at μ = 0.25 in 2 of 3 runs (one flap on c_f,u) |
