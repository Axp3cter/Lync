# Inbound budgets: server CPU per player, as a derivation

2026-10-15. Prover unit. Settles four claims the design needs before it can derive each inbound budget default
(`design/v5.md` §6.1, §7.5, §4.9; `design/v5-integrity.md`) from a stated input instead of "chosen, unmeasured".
Starting point: `research/refusals-rejudged-1.md` R31 (13.1–17.7 ms/s per player interpreted at the default byte
budgets, from `Run.decode` alone).

## Checklist

- [x] 1. Server decode CPU per inbound byte, by payload shape (worst admitted shape and the busy model), native and
      interpreted, milestone decoder (`f1fbfd7`) and a generated decoder (`decode_shapes.luau`)
- [x] 2. The tag's per-frame and per-byte CPU on the same frames; total inbound CPU = decode + tag (`tag_frames.luau`)
- [x] 3. Per budget (reliable and unreliable `bytes` perSecond and burst; `frames`; `inbound.elements`): formula from
      budget value to worst-case server CPU per player and at 100 players; the busy model's use as a fraction of
      each budget (`derive.py`)
- [x] 4. Budget values at which worst-case inbound CPU at 100 players is 1%, 5%, 10% of one core native; where the
      defaults fall (`derive.py`)

**Host and tools.** CLI VM only: Luau 0.742 built from `.data/projects/luau` (Release), `luau -O2` (interpreted:
Roblox clients, and a server script not marked native) and `luau -O2 --codegen` (native: a Roblox server script
marked `--!native`); Python 3.13.16 for `gen.py` and `derive.py`. Intel Xeon 2.1 GHz, 4 cores, shared machine.
**CLI timings do not transfer exactly to Roblox**: engine costs (remote dispatch, `task.spawn` of handlers, the
engine's own receive path) are not in any figure, and Roblox's native code generator and GC differ from the CLI's.

**Method.** `run.sh BUILD_DIR WORK_DIR` exports `f1fbfd7:src` into `WORK_DIR` (never the repo), exposes three
locals of `src/session/inbound.luau` in that scratch copy (`decodeUp`, `decodingOf`, `process`; one `sed`, no
behaviour change), writes `gen_decoders.luau` with `gen.py`, and runs each probe 3 times per mode into
`<probe>.out`; `python3 -I derive.py > derive.out` aggregates. Frames are built by the milestone's own encoder
(`Run.encode`, `Frame.up`, `Tag.compute`, `Tag.append`) and received by a milestone server runtime assembled in the
probe (all buckets unlimited for timing, no listeners or validators). Each round times every case once over the
same batch of frames after a warm-up, with a full GC before each timed block; 11 rounds. Figures are the median of
the 3 run medians, ranges are the min–max of the run medians unless marked. Within-run spread is ±5–30 % on this
shared host, so the decomposition columns (step 5, rest) are only meaningful where they exceed that; totals (F) are
the decisive figures.

Cases per frame: **D** milestone decode (`Frame.open` + `decodeUp`: header, toc, runs, one `Received` table per
message); **DP** D + step 5 (`process`: counters, unresolved, `limit`, validators, delivery, all empty here);
**F** `Inbound.receive` end to end (shape, frame and byte buckets, tag at the expected count, D, step 5);
**G** the generated decoder (`gen_decoders.luau`: header, toc, runs, straight-line rows and per-field column
reads with constant bounds, values into two flat arrays; checked equal to the milestone's values on every frame
timed). **gen total** = G + (F − D) − milestone tag + generated tag: generated decode and tag, milestone step 5 and
buckets (so an upper figure for a generated build).

Payload shapes: the busy model (`v5.md` §4.1 rates; payloads chosen here because the docs give rates only) is
60 unreliable frames/s each holding one `move6` (`codecs-in-scripts.md`'s 6-field input: `t.int(0,1000)` ×2,
`t.bool()`, `t.number(0,1,1/1024)`, `t.enum` of 3, `t.int(0,255)`; 42 bits) and 10 reliable frames/s each holding
one `sm` (`generation-methods.md` M14's action record: enum of 3, `t.string(32)` with an 8-byte name, `t.int(1,99)`,
`t.optional(t.int(0,15))`). Attack shapes: the same definitions filled to the frame limits, a 32-field and a
128-field all-`t.bool()` record (random, or constant so every column is mode 0), a 1-field record, no-payload
events in one run or in one-message runs, 200-byte strings, and R31's two array rows.

## Results

### 1. Server decode CPU per inbound byte, by shape — **false that R31's figure is the per-byte cost or that the byte buckets bound it; measured below**

Proposition tested: R31's byte-driven figure (dense records, 87–111 ns/B native, 199–271 ns/B interpreted, so
5.7–7.3 / 13.1–17.7 ms/s at the two lanes' 65,536 B/s) is the server's decode CPU per inbound byte, and "the byte
buckets, not `inbound.elements`, bound decode CPU at the defaults".

Probe: `decode_shapes.luau` (+ `gen.py` → `gen_decoders.luau`), output `decode_shapes.out`, aggregated in
`derive.out` ("Claim 1 + 2" tables). Native (`--codegen`), ns per frame, medians of 3 runs:

| Frame (lane: 0 reliable, 1 unreliable) | B | elements | D | F (range) | F ns/B | F ns/element | G | gen total ns/B |
|---|---|---|---|---|---|---|---|---|
| header only, unreliable | 4 | 0 | 959 | 2,188 (2,157–2,418) | 547 | – | 287 | 368 |
| header only, reliable | 3 | 0 | 872 | 1,890 (1,890–2,018) | 630 | – | 251 | 398 |
| **busy input**: 1 `move6`, unreliable | 11 | 1 | 2,796 | 4,698 (4,459–5,511) | 427 | 4,698 | 912 | 251 |
| **busy action**: 1 `sm`, reliable | 15 | 1 | 2,749 | 4,099 (3,887–4,310) | 273 | 4,099 | 936 | 146 |
| `move6` × 192 random, unreliable | 1,000 | 192 | 234,077 | 313,474 (228,116–326,309) | 313 | 1,633 | 92,163 | 170 |
| `move6` × 3,118 random, reliable | 16,380 | 3,118 | 2,899,443 | 3,479,020 (3,452,042–3,516,360) | 212 | 1,116 | 2,065,769 | 160 |
| 32 bools × 4,085 random, reliable | 16,383 | 4,085 | 16,928,951 | 17,394,426 (16,625,160–17,421,020) | **1,062** | 4,258 | 10,442,713 | 664 |
| 200-byte strings × 81, reliable | 16,207 | 81 | 35,971 | 115,175 (111,269–119,735) | 7.1 | 1,422 | – | – |
| 1-field record × 4,096 constant | 7 | 4,096 | 1,431,636 | 2,622,551 (2,213,138–2,630,247) | 374,650 | 640 | 236,376 | (348 ns/el) |
| `move6` × 4,096 constant | 12 | 4,096 | 2,047,808 | 3,217,996 (2,929,443–3,581,168) | 268,166 | 786 | 718,956 | (461 ns/el) |
| 32 bools × 4,096 constant | 15 | 4,096 | 8,696,857 | 8,884,887 (8,597,396–9,731,395) | 592,326 | 2,169 | 2,760,400 | (720 ns/el) |
| 128 bools × 1,024 constant | 39 | 1,024 | 7,835,146 | 7,793,243 (7,358,769–8,358,361) | 199,827 | **7,611** | 4,537,380 | (4,390 ns/el) |
| no-payload event × 4,096, one run | 7 | 4,096 | 865,844 | 1,802,547 (1,736,520–1,917,172) | 257,507 | 440 | 62,627 | (244 ns/el) |
| 4,096 one-message runs (2 no-payload events alternating) | 2,566 | 4,096 | 2,984,231 | 3,477,794 (3,148,860–3,952,649) | 1,355 | 849 | 661,706 | 448 |
| R31 row 1: `t.array(t.bool(), 65535)` all false | 6 | 65,536 | 1,780,595 | 1,819,827 | – | 27.8 | – | – |
| R31 row 2: `t.array({a = t.bool()}, 65535)` all false | 6 | 65,536 | 7,070,512 | 8,043,655 | – | 122.7 | – | – |

Interpreted (`-O2`), F ns/B and ns/element, same frames: header-only 1,077 / 1,218 ns/B (4.3 / 3.7 µs per
frame); busy input 750 ns/B (8,244 ns per frame); busy action 474 (7,110); `move6` dense 391 (1,000 B) and 411
(16 KB); 32 bools random **2,081 ns/B**; strings 32; per element: 1-field constant 734, `move6` constant 1,213,
32 bools constant 4,164, 128 bools constant **14,980**, one run of no-payload events 590, one-message runs 1,319;
R31 rows 64.8 and 175.2. Generated (G) interpreted: busy input 1,263 ns per frame, busy action 1,270, `move6`
16 KB 175 ns/B, 32 bools random 1,073 ns/B (all in `derive.out`).

What decides it:
- **The harness reproduces R31 where R31 measured the same thing.** R31's array rows (`Run.decode` alone) were
  21.6–27.2 and 125.7–132.3 ns/element native, 64.9–71.7 and 178–212 interpreted; the whole path here gives 27.8 and
  122.7 native, 64.8 and 175.2 interpreted: those rows are pure decode, so the two agree.
- **For dense records the whole path costs 2–3× R31's per-byte figure.** The same 6-field random record costs
  177 ns/B in `decodeUp` alone and **212–313 ns/B** native end to end (391–411 interpreted), against R31's 87–111
  (199–271). The difference is per message, outside `Run.decode`: a 9-field `Received` table per message in
  `push` (inbound.luau:177) and step 5 (`process`, 81–690 µs per dense frame, 220–420 ns per message native, 310–380 interpreted).
- **The costliest byte-bound shape measured, 1-bit fields, costs 5× the dense record**: 1,062 ns/B native, 2,081
  interpreted (32 `t.bool()` fields, random). At the two lanes' 65,536 B/s that is 69.6 ms/s per player native
  (136 ms/s interpreted), against R31's 5.7–7.3 (13.1–17.7). Not proven a maximum: it is the highest of the shapes
  timed.
- **The element bucket does not bound CPU by itself; the widest client-sent record does.** Constant columns cost
  bytes ≈ 0 (7–39 B for 1,024–4,096 messages), so they are element-bound, and the cost per element grows with the
  record's field count: 440 (no payload) – 640 (1 field) – 786 (6) – 2,169 (32) – 7,611 (128) ns native,
  590–14,980 interpreted. Native milestone fit over 1–128 fields: about 585 + 55 × F ns per element (F = leaf
  fields per message; 915 predicted against 786 measured at F = 6). At 20,000 elements/s that is 8.8 ms/s per
  player native with no payload, 12.8 at 1 field, 15.7 at 6, 43 at 32 and 152 at 128. The byte buckets, measured
  the same way, give 13.9–20.5 ms/s for dense 6-field records and 69.6 for 1-bit fields at 65,536 B/s. So which
  bucket binds depends on the schema: element-driven CPU reaches dense byte-driven CPU at about 6 fields per
  message, and passes the 1-bit byte worst between 32 and 128 fields. R31 timed 1-field records only.
- **Busy frames are dominated by the per-frame fixed cost**: 1.9–2.2 µs native (3.7–4.3 interpreted) of a
  4.1–4.7 µs frame is the header-only cost (buckets, tag, reader and `Decoding` tables, header, toc, `pcall`).
- **Generated decode** (G against D on the same frames): 1.4–3.5× faster on byte-bound frames (busy 2.9–3.1×,
  `move6` dense 1.4–2.5×, 32 bools random 1.6×), 1.7–13.8× on element-bound ones. With the milestone's step 5 and
  buckets kept (gen total), busy frames fall to 2.2–2.8 µs native and dense ones to 160–170 ns/B; step 5 and the
  fixed costs are then most of what is left.

Tool: Luau 0.742 (`luau -O2`, `luau -O2 --codegen`), `f1fbfd7:src`, 3 runs per mode.

### 2. The tag on the same frames — **true for claim 8's per-byte figures; false that inbound CPU = decode + tag**

Proposition tested: `probes/security-costs/RESULTS.md` claim 8's tag figures (native 3.82–3.87 ns/B generated
loop, 2.15–2.20 unrolled, fixed 0.19–0.25 µs; interpreted 37.5–38.7 and 27.9–33.4 ns/B) hold on these frames,
and a player's total inbound CPU is decode + tag.

Probe: `tag_frames.luau` (part A: one tag per frame, cover 16,384, sizes 3–16,384 B; part B: the milestone's
`Inbound.receive` on frames whose tag is wrong), output `tag_frames.out`, aggregated in `derive.out` ("Claim 2").
The generated forms are `probes/security-costs/hsip.luau`'s `tag13` (loop) and `tag13u4` (unrolled ×4).

One tag, fit = smallest frame + slope (reliable: 1,024 → 16,384 B; unreliable: 4 → 1,000 B), medians of 3 runs:

| Form | native | interpreted |
|---|---|---|
| milestone `Tag.compute` (scratch copy + `HalfSipHash.hash` 1-3/32, 16-bit output) | 196 ns + 3.99 ns/B (unreliable 201 + 4.20) | 890 ns + 30.7 ns/B (932 + 27.4) |
| generated loop (`tag13`) | 61 ns + 3.86 ns/B | 961 ns + 37.2 ns/B |
| generated unrolled ×4 (`tag13u4`) | 122 ns + 2.20 ns/B (157 + 2.25) | 757 ns + 28.5 ns/B |

16,384 B frame, one tag: milestone 67.1 µs native (66.3–67.7), 490 µs interpreted; unrolled 36.4 µs / 462 µs.

Share of the end-to-end frame (F, claim 1 table), native: header-only frames 10 % (196 of 1,890 ns); busy input
4.9 % (230 of 4,698), busy action 6.0 %; dense `move6` 16 KB 1.9 %; 16 KB of strings 56 % (64.8 of 115.2 µs).
Interpreted: busy input 13.6 %, 16 KB strings 95 %.

Wrong tags through the milestone pipeline (part B), ns per frame, native (interpreted):

| Frame | wrong tag | wrong tag, pending key | over the byte budget, wrong tag, pending key | hashes |
|---|---|---|---|---|
| reliable 3 B | 2,530 (7,084) | 3,474 (12,372) | 2,863 (11,283) | 5 / 10 / 10 |
| reliable 1,024 B | 23,521 (154,244) | 46,273 (317,963) | 44,985 (306,821) | 5 / 10 / 10 |
| reliable 16,384 B | 330,457 (2,387,274) | **652,045** (4,935,173) | **655,838** (4,704,955) | 5 / 10 / 10 |
| unreliable 4 B | 2,598 (4,533) | 3,079 (6,915) | – (refused before the tag) | 3 / 6 |
| unreliable 1,000 B | 10,791 (60,526) | 19,645 (119,710) | – | 3 / 6 |

What decides it:
- **Per-byte figures: true.** Native milestone 3.99–4.20 ns/B against claim 8's loop 3.82–3.87; unrolled 2.20
  against 2.15–2.20. Interpreted: loop 37.2 against 37.5–38.7, unrolled 28.5 against 27.9–33.4; the milestone's
  own form is 30.7 (its 22 ns/B was not reproduced here either).
- **Not decode + tag, for three reasons.** (a) 0.7–1.0 µs native of every frame (1.2–1.7 µs interpreted) is
  neither decode nor tag: shape check, two bucket refills with `os.clock()`, reader, `Decoding` and segment tables,
  a 3-element table per unreliable match, replay window, `pcall` (the "rest" column in `derive.out`). Step 5 adds
  220–420 ns per message native. (b) A frame whose tag does not match costs up to 5 hashes on the reliable lane
  (counts e … e + 4, inbound.luau:816–848) and 3 on the unreliable lane (three seq extensions, inbound.luau:850–893),
  and twice that while a pending key exists. A client creates that state itself: 8 wrong tags give `desync` and
  `Handshake.rekey` (handshake.luau:338–344, at most once per 60 s), and `pendingKey` is cleared only by
  `REKEY-ACK` (inbound.luau:370–378), which the client need never send. So a paid 16 KB reliable frame can cost
  652 µs native, 9.7× the single tag. (c) Reliable frames refused at the buckets are still tag-checked
  (inbound.luau:980–988, as `v5.md` §6.1 step 2 says), so they cost 656 µs per 16 KB frame while using no budget.
  Their rate is limited only by the engine: "approximately 500 requests per second, per client", shared per remote
  type (documented, quoted in `research/client-security.md` §2.1). That is 328 ms/s per player native at 16 KB,
  22.5 ms/s at 1 KB, and 1.4 ms/s at 3 B. Whether the engine delivers 8 MB/s from one client is unmeasured.
- So per frame: total = the header-only frame's cost (1.9–2.2 µs native, 3.7–4.3 interpreted: buckets, one tag, header,
  toc) + the payload's decode + 220–420 ns × messages
  (step 5) + (k − 1) extra tags, where k ≤ 10 reliable or 6 unreliable for frames whose tag fails, plus the
  same k tags for every engine-delivered reliable frame over budget.

Tool: Luau 0.742 (`luau -O2`, `luau -O2 --codegen`), `f1fbfd7:src`, `probes/security-costs/hsip.luau`, 3 runs per
mode.

### 3. Formula from each budget to worst-case CPU, and the busy model's share — **true (derived); the element term needs the schema's widest client-sent record as an input**

Proposition tested: each inbound budget maps to worst-case server CPU per player by a stated formula, with the
busy model's use as a fraction of each budget.

Probe: `derive.py` over `decode_shapes.out` and `tag_frames.out`, output `derive.out` ("Claim 3"). Model (the
docstring of `derive.py` has it in full): an attacker sends x_j frames per second of each timed frame kind j (claim
1's frames, and claim 2's wrong-tag frames with a pending key, which are paid for and refused at the tag). The
five buckets bound them: per lane Σ x_j ≤ `frames.perSecond` and Σ x_j·bytes_j ≤ `bytes.perSecond`, and over both
lanes Σ x_j·elements_j ≤ `elements.perSecond`. Worst-case CPU is the linear program max Σ x_j·cpu_j. It scales
linearly with the limits, and at the optimum (LP duality)

  **CPU per player per second = λ_Fr·Fr + λ_Br·Br + λ_Fu·Fu + λ_Bu·Bu + λ_E·E**

where Fr, Br, Fu, Bu, E are the reliable and unreliable `frames` and `bytes` perSecond and `inbound.elements`
perSecond, and λ is each limit's shadow price, in ns per frame, byte or element. This holds exactly while the same
limits bind. At 100 players multiply by 100; one core = 10^9 ns per second.
- **Bursts.** Over a window of T seconds after an idle period every limit is perSecond·T + burst, so the bursts add
  λ_Fr·burst_Fr + λ_Br·burst_Br + λ_Fu·burst_Fu + λ_Bu·burst_Bu + λ_E·burst_E once per refill: "first second"
  below is T = 1.
- **One frame.** A frame's element allowance is the element bucket's whole tokens (`v5.md` §4.8), so one frame can
  cost burst_E × (ns per element of the widest record) up to 16,384 B: 42 ms native at 1 field, 51.5 ms at 6 fields
  (`move6`), 142 ms at 32 and 499 ms at 128, at the default burst of 65,536 (milestone; generated 22.8, 30.2, 47.2,
  288 ms; interpreted milestone 48, 80, 273, 982 ms).
- **Engine-bound term.** Reliable frames refused at the buckets are outside the LP (claim 2): + (frames the engine
  delivers per second beyond Fr) × 10 tags of min(16,384, frame bytes). That is 2.9–656 µs native per frame, up to
  328 ms/s per player at the documented ~500 calls/s.
- Schemas, since the attacker can only send the game's own definitions: **S1** busy-like (`move6`, `sm`, 200-byte
  strings, no-payload events; adding R31's 1-field record and arrays, S2, changes nothing); **S3** S1 plus a
  32-field `t.bool()` record; **S4** S3 plus a 128-field one. These are lower bounds on the true worst case: the LP
  only uses frames that were timed.

Shadow prices and worst case at the defaults (Fr 120, Br 32,768, Fu 240, Bu 32,768, E 20,000 per second;
bursts 240, 65,536, 480, 65,536, 65,536), per player:

| Path, schema | λ_Fr ns/frame | λ_Br ns/B | λ_Fu ns/frame | λ_Bu ns/B | λ_E ns/element | sustained ms/s | 100 players, % of one core | first second ms |
|---|---|---|---|---|---|---|---|---|
| milestone native, S1 | 3,300 | 57.6 | 2,460 | 155 | 812 | **24.2** | **242 %** | 93.3 |
| milestone native, S3 | 1,910 | 521 | 994 | 521 | 2,170 | 78.0 | 780 % | 289 |
| milestone native, S4 | 3,350 | 41.9 | 3,010 | 16.6 | 7,610 | 155 | 1,552 % | 660 |
| generated native, S1 | 2,520 | 71.9 | 2,500 | 78.7 | 460 | 15.0 | 150 % | 56.9 |
| generated native, S3 | 1,280 | 485 | 877 | 484 | 718 | 46.5 | 465 % | 158 |
| generated native, S4 | 2,660 | 24.1 | 2,800 | 4.93 | 4,390 | 89.7 | 897 % | 381 |
| milestone interpreted, S1 | 11,500 | 301 | 6,310 | 152 | 1,210 | 41.9 | 419 % | 157 |
| milestone interpreted, S3 | 9,240 | 1,040 | 2,740 | 1,040 | 4,160 | 153 | 1,533 % | 566 |
| milestone interpreted, S4 | 11,500 | 301 | 6,460 | 113 | 15,000 | 316 | 3,156 % | 1,329 |
| generated interpreted, S1 | 10,200 | 279 | 5,910 | 111 | 652 | 28.5 | 285 % | 102 |

Check of the formula, milestone native S1: 3,300 × 120 + 57.6 × 32,768 + 2,460 × 240 + 155 × 32,768 + 812 × 20,000 =
0.40 + 1.89 + 0.59 + 5.08 + 16.24 = 24.2 ms/s. The attack mix the LP picks there: 31.9/s unreliable 1,000 B
`move6` frames, 1.6/s reliable 16 KB `move6` frames, 2.1/s frames of 4,096 one-message runs, and wrong-tag frames
of 3–4 B on the remaining frame budget (116/s reliable, 208/s unreliable). Every limit binds.

Per-budget reading of the prices (milestone native):
- **`bytes.perSecond`**: 16.6–521 ns/B at the optimum. The byte-bound shapes alone cost 212–313 ns/B for dense
  6-field records and 1,062 ns/B for 1-bit fields; the price is lower where elements bind first.
- **`bytes.burst`**: same price, once per refill: 65,536 × 155 ns = 10.2 ms (S1, unreliable).
- **`inbound.elements`**: 812–7,610 ns per element, which is the widest record's per-element cost (claim 1:
  ≈ 585 + 55 × F ns native, F = fields per message). This is the largest term at the defaults in every schema
  (16.2 of 24.2 ms/s in S1, 152 of 155 in S4).
- **`elements.burst`**: 65,536 × λ_E = 53 ms (S1) to 499 ms (S4) once per refill, and up to that much in one frame.
- **`frames.perSecond`**: 2.5–3.4 µs per frame (the header-only frame, or a wrong tag with a pending key):
  120 × 3.3 + 240 × 2.5 µs ≈ 1.0 ms/s per player whatever the bytes.

Busy model (`derive.out` "busy model"): input frame 11 B, action frame 15 B as built (16-bit tag, no ack); "design"
adds the 32-bit tag (+2 B per frame) and an ack on 20 of the 60 unreliable frames (+28 bits each). Its own cost is
323 µs/s per player native milestone (3.2 % of one core at 100 players), 187 generated (1.9 %), 566 interpreted
milestone (5.7 %).

| Budget | default perSecond | busy use (design) | fraction of perSecond | burst | largest busy frame / burst |
|---|---|---|---|---|---|
| `inbound.reliable.frames` | 120 | 10 | 0.083 | 240 | 0.0042 |
| `inbound.reliable.bytes` | 32,768 | 170 B/s | 0.0052 | 65,536 | 0.00026 (17 B) |
| `inbound.unreliable.frames` | 240 | 60 | 0.25 | 480 | 0.0021 |
| `inbound.unreliable.bytes` | 32,768 | 850 B/s | 0.026 | 65,536 | 0.00026 (17 B) |
| `inbound.elements` | 20,000 | 70 | 0.0035 | 65,536 | 0.000015 |

The reliable byte burst's other honest use is the join hold: 32,768 B (§4.9) is 0.5 of 65,536.

Tool: Python 3.13.16 (`derive.py`, stdlib only), over the Luau 0.742 runs of claims 1 and 2.

### 4. Budget values for 1 %, 5 % and 10 % of one core at 100 players, native — **derived; 1 % is unreachable for any budget set that admits the busy model, and no single budget reaches even 10 % with the others at their defaults**

Probe: `derive.py`, output `derive.out` ("Claim 4"), native rows. Target per player = target × 10^9 ns / 100:
1 % = 100 µs/s, 5 % = 500 µs/s, 10 % = 1,000 µs/s per player. All figures assume over-budget reliable frames are
not tag-checked (claim 2's engine-bound term). With them, the table has no bound: 1.4–328 ms/s per player at
~500 calls/s.

**Where the defaults fall.** Worst case at the defaults, 100 players, native: milestone S1 242 % of one core
(24× the 10 % line, 48× the 5 % line, 242× the 1 % line), S3 780 %, S4 1,552 %; generated S1 150 %, S3 465 %,
S4 897 %. Interpreted milestone S1 419 %.

**(a) Every perSecond scaled from its default by one factor a** (the LP is linear in the limits, so
a = target ÷ worst case at the defaults; bursts are not part of the sustained figure):

| Path, schema | target | a | `reliable.frames` | `reliable.bytes` B/s | `unreliable.frames` | `unreliable.bytes` B/s | `elements` /s |
|---|---|---|---|---|---|---|---|
| defaults | – | 1 | 120 | 32,768 | 240 | 32,768 | 20,000 |
| milestone, S1 | 1 % | 0.0041 | 0.50 | 135 | 0.99 | 135 | 83 |
| milestone, S1 | 5 % | 0.0207 | 2.48 | 677 | 4.96 | 677 | 413 |
| milestone, S1 | 10 % | 0.0413 | 4.96 | 1,354 | 9.92 | 1,354 | 827 |
| milestone, S3 | 10 % | 0.0128 | 1.54 | 420 | 3.08 | 420 | 257 |
| milestone, S4 | 10 % | 0.0064 | 0.77 | 211 | 1.55 | 211 | 129 |
| generated, S1 | 1 % | 0.0066 | 0.80 | 218 | 1.60 | 218 | 133 |
| generated, S1 | 5 % | 0.0332 | 3.99 | 1,089 | 7.98 | 1,089 | 665 |
| generated, S1 | 10 % | 0.0665 | 7.98 | 2,178 | 15.95 | 2,178 | 1,329 |
| generated, S3 | 10 % | 0.0215 | 2.58 | 705 | 5.16 | 705 | 430 |
| generated, S4 | 10 % | 0.0112 | 1.34 | 365 | 2.68 | 365 | 223 |

(S3 and S4 at 1 % and 5 % are in `derive.out`: a = 0.0013 and 0.0064 for milestone S3, 0.0006 and 0.0032 for S4.)
Every row in (a) refuses the busy model: it needs 10 reliable and 60 unreliable frames a second.

**(b) One budget varied, the other four at their defaults:** unreachable at every target, in every schema and
both paths. The floor (that budget set to 0) is still, milestone native S1: 106.5 % with either reliable budget at
0, 185 % with either unreliable budget at 0, and 30.4 % with `elements` at 0. The 30.4 % is undecoded work alone:
fixed costs on the frame budgets, plus wrong-tag frames with a pending key on the byte budgets. Generated:
60.0 %, 119 %, 19.4 %.

**(c) Budgets = m × the busy model's use** (design bytes: 10 and 60 frames, 170 and 850 B/s, 70 elements). This
is the smallest budget set that admits the busy model. m = target ÷ the worst case at m = 1:

| Path, schema | worst case at m = 1 | 1 % | 5 % | 10 % |
|---|---|---|---|---|
| milestone, S1 | 343 µs/s per player = 3.43 % | unreachable (m 0.29) | m = 1.46: 14.6 / 248 / 87.6 / 1,240 / 102 | m = 2.92: 29.2 / 496 / 175 / 2,481 / 204 |
| milestone, S3 | 5.28 % | unreachable | unreachable (m 0.95) | m = 1.89: 18.9 / 322 / 114 / 1,608 / 133 |
| milestone, S4 | 7.68 % | unreachable | unreachable (m 0.65) | m = 1.30: 13.0 / 221 / 78.1 / 1,107 / 91 |
| generated, S1 | 2.62 % | unreachable (m 0.38) | m = 1.91: 19.1 / 325 / 115 / 1,624 / 134 | m = 3.82: 38.2 / 650 / 229 / 3,249 / 268 |
| generated, S3 | 3.87 % | unreachable | m = 1.29: 12.9 / 220 / 77.5 / 1,098 / 90 | m = 2.58: 25.8 / 439 / 155 / 2,196 / 181 |
| generated, S4 | 5.10 % | unreachable | unreachable (m 0.98) | m = 1.96: 19.6 / 334 / 118 / 1,668 / 137 |

(values: `reliable.frames` / `reliable.bytes` B/s / `unreliable.frames` / `unreliable.bytes` B/s / `elements`/s.)
Interpreted milestone S1's floor is 7.49 % (10 % at m = 1.34).

What decides it:
- The busy model alone costs 3.2 % of one core at 100 players native (milestone; 1.9 % generated), so 1 % cannot be
  met by budgets at all with these per-frame costs. Its inputs are the fixed cost per frame (1.9–2.2 µs native),
  step 5 per message (220–420 ns) and the tag. Budgets only bound the attacker's extra above that.
- The defaults sit 24–155× above the 10 % line (milestone native, S1–S4). The two largest terms are
  `inbound.elements` (λ_E = 812–7,610 ns, fixed by the widest client-sent record) and the byte buckets (λ_B up to
  521 ns/B with 1-bit records). The frame budgets contribute about 1.0 ms/s per player (10 % at 100 players) on
  their own.
- Inputs the architect sets besides the budget values, each with a measured price: the per-element cost of the
  widest client-sent record (claim 1: ≈ 585 + 55 × F ns), the per-frame fixed cost, the tag's hash count on a
  failing frame (5 + 5 with a pending key; 3 + 3 unreliable), and whether over-budget reliable frames are hashed.

Tool: Python 3.13.16 (`derive.py`), over the Luau 0.742 native runs.

## Summary

| Claim | Verdict | Decisive figure |
|---|---|---|
| 1. Decode CPU per byte | false that R31's 87–111 ns/B (native) is the cost or that the byte buckets bound it | whole path 212–313 ns/B for dense records, 1,062 for 1-bit fields; constant columns 440–7,611 ns per element at ≈ 0 B |
| 2. Tag | true for claim 8's per-byte figures (4.0 ns/B milestone, 2.2 unrolled, native); false that total = decode + tag | failing tags cost up to 10 hashes (652 µs per 16 KB frame native) and over-budget reliable frames are hashed outside every budget |
| 3. Formula | true (derived): CPU = Σ λ_k × limit_k, plus λ·burst once per refill | defaults, milestone native S1: 24.2 ms/s per player (242 % of one core at 100 players); busy model uses 8.3 % / 25 % of the frame budgets, 0.5 % / 2.6 % of the byte budgets, 0.35 % of elements |
| 4. 1 / 5 / 10 % table | derived; 1 % unreachable while admitting the busy model | 10 % needs every budget at 0.041× default (milestone S1), or 2.9× the busy model's use |
