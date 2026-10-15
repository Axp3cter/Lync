# Inbound budgets: server CPU per player, as a derivation

2026-10-15. Prover unit. Settles four claims the design needs before it can derive each inbound budget default
(`design/v5.md` §6.1, §7.5, §4.9; `design/v5-integrity.md`) from a stated input instead of "chosen, unmeasured".
Starting point: `research/refusals-rejudged-1.md` R31 (13.1–17.7 ms/s per player interpreted at the default byte
budgets, from `Run.decode` alone).

## Checklist

- [x] 1. Server decode CPU per inbound byte, by payload shape (worst admitted shape and the busy model), native and
      interpreted, milestone decoder (`f1fbfd7`) and a generated decoder (`decode_shapes.luau`)
- [x] 2. The tag's per-frame and per-byte CPU on the same frames; total inbound CPU = decode + tag (`tag_frames.luau`)
- [ ] 3. Per budget (reliable and unreliable `bytes` perSecond and burst; `frames`; `inbound.elements`): formula from
      budget value to worst-case server CPU per player and at 100 players; the busy model's use as a fraction of
      each budget (`derive.py`)
- [ ] 4. Budget values at which worst-case inbound CPU at 100 players is 1%, 5%, 10% of one core native; where the
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
  `push` (inbound.luau:177) and step 5 (`process`, 81–690 µs per dense frame, about 220 ns per message native).
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
  about 220 ns per message native. (b) A frame whose tag does not match costs up to 5 hashes on the reliable lane
  (counts e … e + 4, inbound.luau:816–848) and 3 on the unreliable lane (three seq extensions, inbound.luau:868–893),
  and twice that while a pending key exists. A client creates that state itself: 8 wrong tags give `desync` and
  `Handshake.rekey` (handshake.luau:338–344, at most once per 60 s), and `pendingKey` is cleared only by
  `REKEY-ACK` (inbound.luau:367–377), which the client need never send. So a paid 16 KB reliable frame can cost
  652 µs native, 9.7× the single tag. (c) Reliable frames refused at the buckets are still tag-checked
  (inbound.luau:976–984, as `v5.md` §6.1 step 2 says), so they cost 656 µs per 16 KB frame while using no budget.
  Their rate is limited only by the engine: "approximately 500 requests per second, per client", shared per remote
  type (documented, quoted in `research/client-security.md` §2.1). That is 328 ms/s per player native at 16 KB,
  22.5 ms/s at 1 KB, and 1.4 ms/s at 3 B. Whether the engine delivers 8 MB/s from one client is unmeasured.
- So per frame: total = fixed pipeline (≈ 1.7–2.0 µs native including one tag) + decode + 220 ns × messages
  (step 5) + (k − 1) extra tags, where k ≤ 10 reliable or 6 unreliable for frames whose tag fails, plus the
  same k tags for every engine-delivered reliable frame over budget.

Tool: Luau 0.742 (`luau -O2`, `luau -O2 --codegen`), `f1fbfd7:src`, `probes/security-costs/hsip.luau`, 3 runs per
mode.
