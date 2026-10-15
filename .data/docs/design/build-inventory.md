# Build inventory: what milestones 1–2 at `f1fbfd7` teach the next build

Scout brief, 2026-10-15. Sources: `git show f1fbfd7:<path>` (cited `f1fbfd7:<path>:<line>`), `m1-plan.md`,
`m2-plan.md`, `reviews/m1-code.md`, `reviews/simplifications.md`, `probes/build/`, the ledger at
`f1fbfd7:.data/docs/agents.md`, and the build's git history (`c16fb47..f1fbfd7`). Paths without a prefix are under
`.data/docs/`. Measurements marked **(rerun)** were made by this scout on an extract of `f1fbfd7` (`git archive`,
outside the working tree) with Lune 0.11.0 and luau-lsp 1.70.1 from the luau skill cache.

**Read and skimmed.** Read in full: both plans, `m1-code.md`, the `src`/`docs/codes` parts of `simplifications.md`,
`probes/build/README.md`, every `test/support/*.luau`, `test/run.luau`, `test/types/run.sh`,
`test/golden/golden.spec.luau`, `f1fbfd7:src/session/state.luau`, `src/sched/scheduler.luau`, the module headers of
all 40 `src` files, `src/session/inbound.luau:340-1101`, `src/sched/outbox.luau:130-390`. Skimmed (exports,
requires, constants, named regions only): the other `src` bodies, the spec bodies (test names read for every spec),
`docs/codes/*.md` (front matter counted, `overBudget.md` read), the benchmark files. `v5.md` §2, §9, §10 skimmed;
details of draft 3.6 are cited only as "in progress".

Status (each section written in its own edit):
- [x] 1. Module map of `f1fbfd7`
- [x] 2. Test harness
- [x] 3. Tooling and config
- [x] 4. Lessons
- [x] 5. Reusable as is, with changes, discard
- [x] 6. Unit sizing evidence
- [x] Open questions

## 1. Module map of `f1fbfd7`

40 source files, 15,611 lines (`src/**/*.luau`). Every file is `--!strict` and ends `return table.freeze(X)`, except
`types.luau` (`--!nocheck`, `--!nolint UnknownGlobal`, `f1fbfd7:src/types.luau:1-2`). Requires are relative strings;
only `init.luau` uses `@self/` (`f1fbfd7:src/init.luau:15-17`). Owner is the builder unit of `m1-plan.md` §3 /
`m2-plan.md` §4. Exports are the module table's fields and exported types (from `function X.f` / `export type`).

| File | Lines | Unit | Purpose | Exports | Requires | Design |
|---|---|---|---|---|---|---|
| `wire/bits` | 374 | A (+D `copy`) | LSB-first bit section plus reversed tail; never raises on read | `Writer`, `Reader`; `writer write align writeTail parts finish reader read readAlign readTail meets charge copy` | — | §4.1, §4.2, §4.8 rule 10 |
| `wire/ints` | 329 | A | bit lengths, widths, zigzag, EG-k with 12-bit LUT and batched `readEgMany` | `MAX bitLength width zigzag unzigzag egBits writeEg readEg readEgMany` | bits | §4.1, §4.3 |
| `wire/column` | 449 | A | integer column coder, 4 modes, exact to 2^53 | `MIN_ROWS`(=3, `:322`) `choose read write` | bits, ints | §4.3, §4.9 |
| `wire/quant` | 533 | A | number, angle, octahedral direction, smallest-three rotation, colour; canonical iteration | `AXIS numberSteps number unnumber angleSteps angle unangle direction undirection directionIsCanonical rotation unrotation color uncolor` | diag/fail | §3.3 |
| `wire/halfsiphash` | 123 | A | HalfSipHash c/d rounds, 4/8-byte out, IV parameters | `hash` | — | §4.5, §4.6 |
| `wire/limits` | 67 | A (fix A6) | shared int range, f32 spacing, integer/finite tests | `INT_MIN INT_MAX f32Spacing isInteger isFinite` | — | §3.3 |
| `plan/dsl` | 1,075 | B | the `t` constructors and `event/request/collection`; records `debug.info(2,"sl")` | `types event request collection isCodec isRecord toFinite toName IS_KEY_KIND`; types `Node Codec Part Declaration` | diag/fail, wire/limits, wire/quant | §3.3, §3.4 |
| `plan/ir` | 167 | B | IR types only | `Codec NumberCodec RotationCodec MapCodec RecordCodec CustomCodec Field Variant Definition Entry Namespace` | wire/bits | §3.3–§4.7 |
| `plan/planner` | 1,333 | B | options, name order, `:newest()`, widths, id spaces, worst-case bits/tail/elements W, hash | `plan` | wire/column, dsl, diag/fail, wire/ints, ir, wire/limits, serialize | §3.1, §3.4, §4.6–§4.9 |
| `plan/serialize` | 226 | B | canonical serialization and HalfSipHash-2-4 schema hash | `bytes hash` | wire/halfsiphash, ir | §4.6, §4.7 |
| `types` | 402 | B | type functions `Infer Tagged Partial OptionValue FromOf KeyOf SideOf`, views, `Result`, `Failure` | `Codec<T> T Event Request Collection Schema ServerView ClientView …` | wire/bits, plan/ir | §3.2, §3.5 |
| `init` | 57 | B | milestone 1 surface only | `types event request collection schema` | plan/dsl, plan/planner, types | §3 |
| `codec/leaves` | 1,062 | C | leaf codes and values, refusals, chunk instances, rollback, canonical rotation | `Instances Refusal Root Chunk Miss`; 30 functions (`canonicalRotation rollBack instanceCode newRecord sortedKeys …`) | wire/bits, diag/fail, wire/ints, plan/ir, wire/limits, wire/quant | §3.3, §4.2 |
| `codec/rows` | 879 | C | single-row encode/decode; inner arrays ≥ MIN_ROWS become column blocks | `beginChunk collect encodeValue endChunk read write` | wire/bits, wire/column, columns, wire/ints, plan/ir, leaves, wire/quant | §3.3, §4.3, §4.8 |
| `codec/columns` | 1,206 | C | column-block flattening | `collect read write` | wire/bits, wire/column, plan/ir, leaves, wire/quant | §4.3 |
| `codec/run` | 165 | C | a run's payloads: rows below MIN_ROWS, else one block | `collect decode encode` | wire/bits, wire/column, columns, plan/ir, leaves, rows | §4.3 |
| `diag/codes` | 183 | B, then E | code registry: `Code` union, family and evidence order | `Family Code`; `family evidence` | — | §7.1–§7.3 |
| `diag/fail` | 287 | B | one message grammar; caller position by `debug.info` walk | `At`; `NONE caller declaration show` | codes | §7.1 |
| `diag/facts` | 496 | E | coalescing, caps, `suppressed`, observers via `host.spawn` | `Fact State`; `new configure forget observe record sweep` | codes, console, counters, host/host | §7.3 |
| `diag/counters` | 187 | E | slot counters, frozen snapshots | `State`; `new add forget slot snapshot` | — | §7.4 |
| `diag/console` | 209 | E | ≤ 2 constant-text lines per code per window | `State`; `new configure enable fact sweep` | codes, host/host | §7.4 |
| `host/host` | 68 | E | the `Host`/`Transport` seam, types only | `Lane Connection Transport Host` | — | `m2-plan.md` §2 |
| `host/roblox` | 276 | E | real `Host` from services; remotes under `ReplicatedStorage.Lync` | `host` | host | §4.1, §7.4 |
| `transport/seq` | 48 | D | 12-bit seq extension | `extend` | — | §4.4 |
| `transport/header` | 231 | D | down reliable/unreliable and up headers | `Ack`; `write/read DownReliable DownUnreliable Up` | wire/bits, host/host | §4.1 |
| `transport/toc` | 137 | D | toc lists, rule 6 checks | `Segment`; `read write` | wire/bits, wire/ints | §4.1 |
| `transport/control` | 495 | D | control chunks, 8 types | `Hello First Welcome Rekey Rate Report`; `HELLO…RATE read write` | wire/bits, wire/ints, codec/leaves | §4.6 |
| `transport/frame` | 328 | D | chunks, frames, size splits, `open` | `Chunk Kind`; `chunk down fits open up` | wire/bits, header, host/host, wire/ints, toc | §4.1, §4.2, §4.9 |
| `transport/tag` | 113 | D | HalfSipHash-1-3, **low 16 bits** (`:25-26`) | `append compute read` | wire/halfsiphash, host/host | §4.5 |
| `session/permutation` | 69 | D | Fisher–Yates id permutation, seed 0 identity | `build` | — | §4.5 |
| `session/replay` | 119 | D | 64-frame RFC 4303 window | `Window`; `new accept newest status` | — | §4.5 |
| `session/buckets` | 82 | E | token buckets, start full | `Bucket`; `new peek take` | — | §5.4, §6.1 |
| `session/state` | 507 | F | the runtime record and its constants; `answer`/`control` callbacks so session can queue without requiring sched (`f1fbfd7:src/session/state.luau:11-12`) | `Limit Config Payload Request Answering Message Definition Namespace Waiting Held Connection Group Target(=any) Mode Runtime`; `ALL EMPTY_PAYLOAD VERSION BUILD_SEED … count fact` | buckets, diag/console, transport/control, diag/counters, diag/facts, transport/frame, host/host, plan/ir, replay | `m2-plan.md` §2 |
| `session/connection` | 148 | F | per-peer state constructor | `ELEMENTS new key reconfigure limitOf` | buckets, replay, state | `m2-plan.md` §3.4 |
| `session/handshake` | 449 | F | `HELLO/WELCOME/MISMATCH/RATE/REKEY` flows | `hello introduce load mismatch rate rekey rekeyed sweep untagged welcome` | 10 modules | §4.5–§4.6, §5.3 |
| `session/requests` | 461 | F | slots, epochs, timeouts, handler threads | `admit begin cancel handle leave match settle shutdown sweep wait` | state | §5.2 |
| `session/inbound` | 1,101 | F | server §6.1 steps 1–7, client decode | `receive` | 19 modules | §6.1, §4.8 |
| `sched/ticks` | 82 | F | state tick T, tick header mode, `RATE` | `advance current mode` | transport/control, session/state | §5.1 |
| `sched/outbox` | 951 | F | encode at call, runs, holds, routing, `FireAllClients` | `answer ask control fire flush` | 14 modules | §4.1–§4.2, §5.3, §5.4 |
| `sched/scheduler` | 137 | F | step loop, client 1/60 s accumulator, `missedFlush` | `flush mode start` | diag/facts, session/handshake, outbox, session/requests, session/state | §5.1 |

Totals by layer: wire 1,875; plan 2,801; diag 1,362; codec 3,312; transport 1,352; session 2,936; sched 1,170;
host 344; `init` + `types` 459. Planned but absent at `f1fbfd7`: `src/api/{runtime,views,targets}.luau` and the
milestone 2 `init.luau` additions (`m2-plan.md` §3.6), `bench/inbound.bench.luau` (§4 unit F), `studio/` (§7).

Layering as built (all requires checked against the list above): `diag` and `host` at the bottom, then
`wire → plan → codec → transport → session → sched`; no file requires a later layer. Two placements differ from
`v5.md` §2's "Runtime layers" ("session (handshake, tag, acks, requests) → sched (flushing, ticks,
budgets)"): the tag is `transport/tag.luau` and the buckets are `session/buckets.luau` (`m2-plan.md` §3.3, §3.4).
No check enforces the layer rule (no test or script scans requires) *(inferred from a search of `test/`)*.

Type check **(rerun)**: `luau-lsp analyze` on `src` is clean on both solvers for every unit A–E file. Unit F's files
are not: new solver 6 errors in `sched/outbox`, 14 in `session/requests`, 6 in `session/state`, 1 in
`session/inbound`; old solver 2 each in `outbox`, `requests`, `inbound` (for example
`f1fbfd7:src/session/requests.luau:160` "Function only returns 1 value, but 2 are required"). Every F module loads
under Lune; `host/roblox` cannot (it calls `game:GetService` at load).

## 2. Test harness

**Runner.** `f1fbfd7:test/run.luau` (117 lines, Lune): finds every `*.spec.luau` under `test/`, requires each, and
runs each named function of the returned table in its own `pcall`; prints failures and `N passed, M failed`, exits 1
on any failure. Filter `lune run test/run.luau [filter]` is a plain substring of `"<spec path> <test name>"`
(`:95-98`); every spec is still required. It copies `Vector3 CFrame Color3 Instance Enum` from `@lune/roblox` into
`getfenv(0)` before any require (`:39-45`, `:76`); the only other `getfenv` uses are the standalone scripts `test/codec/min_rows.luau` and `rotation_full.luau`, none in `src`. Env switches: `LYNC_SEED=<n>` (replay),
`LYNC_FULL=1` (full counts) (`:14-16`). No setup/teardown framework.

**Assertions** (`test/support/check.luau`, 230 lines): `expect`, `expectEqual` (deep; buffers by content; NaN equals
NaN), `expectBytes(actual, hex)` (first differing byte), `expectThrow(fn, { code, at?, subject?, path? })` parsing
`^(.-):(%d+): %[Lync%] (%a+): (.*)$` (`:28`); `subject`/`path` must be whole tokens; prose is never compared.
`expectFact` and `expectQuiet` live in `world.luau` (below).

**Properties** (`test/support/prop.luau`, 79 lines): `Prop.check(name, generate(size), test, { runs?, seed? })`;
200 runs, size 1 → 100; run i reseeds `math.random` with base + i − 1; shrink = regenerate the failing run at halved
sizes; the error names `LYNC_SEED`, run and smallest size. No combinators.

**Generators** (`test/support/gen.luau`, 438 lines): `Gen.codec(depth, size)` builds random DSL codecs (22 leaf
kinds; never an optional where `optionalPlacement` refuses one, `:229-230`); `Gen.plan` plans one as an event's data
through `Lync.schema`; `Gen.plannedCodec` retries until the planner accepts; `Gen.value(codec, size, style)` draws
values **as the codec decodes them** (quantized, canonical direction/rotation, f32-rounded) so a round trip returns
the same value (`:9-11`); `Gen.style` varies absent-optional chance and used variants; `t.custom` is a u10.

**Frame pieces** (`test/support/frame.luau`, 223 lines; owned C, then D): `Frame.arena()` plans `v5.md` §3.4's
`arena`; `writeRunHeader/readRunHeader`, `writeAnswerPrefix/readAnswerPrefix` (slot u4, epoch u1, outcome u2,
`:38-40`), `encodeRun/decodeRun` (a run's payloads alone, rule 4 when bits and tail don't meet).
`test/transport/frames.luau` (535 lines) is a test-only whole-frame decoder standing in for the inbound pipeline
(rule 7 for ids, lanes, unwelcomed namespaces, control direction; no tag) plus a random chunk generator.

**Simulated network** (`test/support/net.luau`, 243 lines). Per link and direction; holds no clock.
- Reliable: arrival = now + latency + jitter·U, then `max(arrival, lastReliableAt)` keeps order; stalls start as a
  Poisson process (`stall.chance`/s) and hold every frame due inside one until its end (`:99-113`).
- Unreliable: over `unreliableLimit` dropped; Gilbert–Elliott burst state (`enter`/`leave` per frame, drops all
  while in it); then `loss`; arrival with its own jitter (reorders); `duplicate` sends a second copy with fresh jitter
  (`:115-139`).
- Randomness: xorshift128 seeded through murmur3's finalizer, 16 warm-up draws (`:65-77`, `:201-224`).
- Defaults `Net.HONEST` (`:144-153`): latency 0.05, jitter 0.02, loss 0.05, burst `{0, 1}`, duplicate 0, stall
  `{0.05, 0.3}`, fps 60, unreliableLimit 1000. `Net.params(base, overrides)` replaces whole fields.

**Simulated world** (`test/support/world.luau`, 743 lines). One virtual clock; server steps at 60 Hz, each client at
its link's `fps`; `world:step(dt)` advances to each due step in time order, delivers every arrived frame (binary heap,
FIFO on ties), then runs that peer's `onStep` (`:723-741`). `Host` per peer: `now` = 1000 + t, `clock` = t,
`entropy32` seeded, `spawn` runs at once in a coroutine and records a raise as a native report, `report`/`warn`
recorded (`:352-422`). Players are frozen tables with `UserId`, `Name`, a recording `Kick`. Frames are copied at
send; delivered only after both ends opened and a handler is set; `world.calls` records `send`/`broadcast`/`raw`
(a broadcast is one call). `World.raw(client, lane, ...)` sends any arguments (the modified-client path).
Assertions: `expectFact(peer, { reason, player?, count?, definition?, evidence? })` claims the earliest match;
`claimLines`, `claimReports`; `expectQuiet` fails on any unclaimed fact, report or console line (`:606-655`).
Runtimes come through an `Endpoint { new, observe }` (`:41-44`); at `f1fbfd7` only a stub endpoint was ever plugged
in (`host/world.spec.luau`); unit F never connected a real runtime, so no honest or modified-client suite exists.

**Golden frames.** `test/golden/index.json` has 65 entries: G1, G2, G2b, G3, G4, G5, G7, G8, G9a, G9b, G10, G11,
`PERM-12345678`, and 52 `Q-*` quantizer vectors (edges of each quantizer, every smallest-three branch, the 24 axis
rotations). Entry shape `{ id, file | bits, milestone, what, design }`; `bits` is a stream-order string for vectors
that end inside a byte (`test/support/golden.luau:34-41`).
- Produced: `.bin` files written once from `v5.md` §4.10's hex and never regenerated by the code under test
  (`m1-plan.md` §4.4); G10 and G11 from `probes/design-3/golden_m2.luau` (`m2-plan.md` §5); the `Q-*` bits by
  `test/wire/quant.golden.luau`, which "requires nothing from `src/`" (its header) and encodes from §3.3 alone.
- Checked: frames are built by `src/transport` around `Run.encode` payloads, compared with `expectBytes`, then the
  `.bin` is opened and decoded back to the values (`golden.spec.luau:230-388`); tagged vectors use key `00…07`,
  count 0, cover 1024. G6 (bytes and hash `ab 86 8b 15 cd 9c 16 40`) is in `test/plan/serialize.spec.luau:32-43`;
  G1 and G9a/b in `test/wire/ints.spec.luau:88-130`; `Q-*` in `test/wire/quant.spec.luau:171`. A meta-test fails if
  any milestone ≤ 2 frame vector is not in its `REPRODUCED` table (`golden.spec.luau:404-419`).
- G4, G5 and G8 carry the **16-bit** tag (`probes/build/README.md`); draft 3.6 in progress changes G4, G5, G6, G7,
  G8 and G10 and adds G4c, DERIVE, W1, W2 (`v5.md` §4.10 "Provenance", in progress).

**Fuzzers and mutation.**
- `test/codec/mutation.spec.luau`: padding flips, truncation, appended byte, map order, rule 9 lists, codes past max
  (each its rule); a seeded random-mutation property (400 runs, 30,000 with `LYNC_FULL`, `:31-32`) that never raises
  and, for single rows, re-encodes accepted input to the same bytes (C8).
- `test/transport/mutation.spec.luau`: one test per rule 2–10 on whole frames both ways, random frames and mutated
  encoder frames (300 / 20,000 runs, `:53-54`), reader budget 65,536 (`:12`).
- `test/transport/frame.spec.luau`: random chunk lists round-trip in every frame kind (200 / 5,000 runs, `:43-44`).
- The review's own fuzzer (`probes/review-m1/p5_fuzz.luau`, 140,000 cases) stayed outside the suite.

**Exhaustive and heavy checks.** In-suite with a `LYNC_FULL` switch: `quant.spec.luau` random counts default
`min(n, 10,000)`, full 10^6 per width (`:17-21`). Outside the suite, run by hand: `test/codec/rotation_full.luau`
(exhaustive codes per width, splittable by part; 10^7 random; worst-case error search),
`test/codec/min_rows.luau` (the `columnMinRows` table). In-suite always: exhaustive 8-bit direction (511
non-canonical), every colour code, every grid code of the `number_steps` cases, sampled 7–8-bit rotations, 20,000
random rotations (`rotation.spec.luau:41`).

**Typing proofs** (`test/types/run.sh`, 84 lines): each `<name>.luau` runs through `luau-analyze --solver=new`
and/or `luau-lsp analyze` on both solvers, output diffed against `<name>.expected` with paths normalised; exit 139 is
a failure; `--update` rewrites expectations. Seven proofs: `arena brand enums request sides typo typo_schema`
**(rerun: 7 PASS, 21.4 s)**.

**Benchmarks.** `bench/column.bench.luau` (Luau CLI, `-O2` and `-O2 --codegen`, one JSON line per result appended to
`bench/results/<sha>.json`): column encode with full k search vs k = 0 on 64-row columns of four patterns, decode,
EG-0 per value and batched, HalfSipHash 64 B / 1024 B. Recorded: `579015b.json` (38 lines), `c91960e.json` (40
lines, has `readEgMany0` 42.9 ns interpreted / 27.9 native, `searchRatio` ≤ 2.58). `test/codec/rotation.bench.luau`
(checked decode 2.56× interpreted, 2.66× native; `test/codec/results/rotation-3a222e0.json`). Copies are in
`probes/build/results/` (byte-identical **(rerun: cmp)**).

**Default vs `LYNC_FULL=1`, counts and times.** Recorded: 242 tests at the review baseline (`m1-code.md:9`); 362
tests and "about 37 s" at milestone 1 close (`m1-plan.md:691`); 430 at unit D's finish (ledger,
`f1fbfd7:.data/docs/agents.md:40`); "wire 4.5 s default" (ledger `:35`). **(rerun)** at `f1fbfd7`: default 430
passed in 35.0 s; `LYNC_FULL=1` 430 passed in 182.3 s. Per directory (default, tests / seconds incl. ~0.4 s load):
wire 63 / 5.1, plan 77 / 18.5, diag 91 / 2.7, codec 96 / 4.9, golden 11 / 0.6, transport 54 / 3.2, session 13 /
0.8, host 25 / 3.2. `plan/sizes.spec.luau` alone is 2 tests and 17.8 s (B11's 20,000 messages per definition);
`registry.spec` 56 and `codec/refusal.spec` 59 are generated per code/case. Test code: 13,530 lines
(`test/**`), of which support 2,047.

## 3. Tooling and config

**At `f1fbfd7`** (root files: `.gitignore default.project.json rokit.toml selene.toml stylua.toml`; no `.luaurc`, no
`scripts/`, no CI workflow, no `wally.toml`/`package.json`; `git ls-tree f1fbfd7`).
- `rokit.toml`: `lune-org/lune@0.11.0`, `rojo-rbx/rojo@7.7.1`, `JohnnyMorganz/luau-lsp@1.70.1`,
  `JohnnyMorganz/StyLua@2.6.0`, `Kampfkarren/selene@0.32.0`. The Luau CLI 0.740 is not rokit-managed; it comes from
  `~/.cache/luau-skill/luau-0.740-linux-x86_64/` (`m1-plan.md:32-33`), as do the Roblox definitions
  `roblox-defs-2857efa82454.luau` used by every type check (`m1-plan.md:85`).
- `stylua.toml`: `syntax = "Luau"`, column 100, Unix endings, **tabs**, width 4, `AutoPreferDouble`,
  `call_parentheses = "Always"`, `collapse_simple_statement = "Never"`, `sort_requires` on. StyLua's output wins
  over the skill's alignment-padding rule (`m1-plan.md:60-61`).
- `selene.toml`: `std = "roblox"`, linting `src` and `bench` only. The plan's lead note says the roblox std could not
  be generated behind the proxy and `std = "luau"` was used "until CI" (`m1-plan.md:530-531`); the committed file
  says `roblox`. `types.luau` carries `--# selene: allow(undefined_variable)` for type-function bodies
  (`f1fbfd7:src/types.luau:3-4`).
- Requires: relative strings everywhere; `@self/` only in `src/init.luau`; tests reach `src` as `../../src/...`.
  Checked on Lune 0.11.0 and Luau 0.740 (`m1-plan.md:16-19`). No aliases were needed, so no `.luaurc`.
- Rojo: `default.project.json` = `{ "name": "lync", "tree": { "$path": "src" } }`, also the `sourcemap.json`
  source. `.gitignore`: `__pycache__/ *.pyc sourcemap.json roblox.yml bench/results/*.tmp`.
- Commands (`m1-plan.md:82-89`): `lune run test/run.luau [filter]`; `luau-lsp analyze --platform=roblox
  --flag:LuauSolverV2=true|false --definitions=@roblox=<defs> src`; `sh test/types/run.sh`;
  `luau -O2 [--codegen] bench/<name>.bench.luau`; `stylua --check src test bench`; `selene src bench`.
  No StyLua or selene result is recorded in the plans, ledger or review; this scout did not run them (neither
  binary is installed here).
- Planned, not built: the Studio kit `studio/` (`m2-plan.md:445-447`), `bench/inbound.bench.luau` (`:362-363`), a
  CI that runs any of the above. `bench/rows.luau` was built as `test/codec/min_rows.luau` (Lune, because it needs
  the codec and Roblox types) (`v5-changes.md:358`).

**The v4 working tree** (`research/v4.md`; files read at HEAD):
- `rokit.toml`: luau-lsp 1.69.0, lune 0.10.5, rojo 7.7.0, StyLua 2.5.2, **wally 0.3.2**, no selene.
- `stylua.toml`: **spaces**, width 4, column 100, `collapse_simple_statement = "ConditionalOnly"`, sort_requires;
  `.styluaignore` excludes `build/ node_modules/ typedefs/`.
- `.luaurc`: `languageMode: strict`, all lints, `lintErrors: true`, aliases `bench fixtures lune(=./typedefs/lune)
  src test`.
- `default.project.json` named `"Lync"`; `wally.toml` `axp3cter/lync` 4.0.3; `package.json` `@axpecter/lync`
  4.0.3 with roblox-ts 3.0.0 and TypeScript 5.5.3; `tsconfig.json` checks the hand-written `index.d.ts` against
  `test/Declaration.ts` and `test/Rejections.ts`.
- `scripts/` (Lune): `run.luau` with commands `setup verify fmt analyze test bench check build`; checks include
  `width` and `edges` ("holding the layer stack", `scripts/run.luau:41-42`). `.github/workflows/ci.yml` runs
  `lune run scripts/run.luau verify` and `check`; `release.yml` adds `bench` and `build`; `docs.yml` runs
  `mkdocs build --strict`. `.vscode/settings.json` enables luau-lsp's new solver with `./typedefs/roblox.d.luau`.
- `typedefs/` vendors Lune and Roblox definitions (19k lines, `research/v4.md:20`); `fixtures/` holds v4 test
  doubles and schemas.

**What v5 keeps or replaces.** Stated: v5 publishes `lync` on Wally, pesde and the Creator Store and `@lync/core` on
npm (`v5.md` §2 "Packages"), so v4's `axp3cter/lync` and `@axpecter/lync` identities and the hand-written `index.d.ts` are
replaced by generated `.d.ts` (milestone 3, `v5.md` §10 item 3); repo tooling "never shipped" is StyLua and selene
with a Lync `std` file, Moonwave, Markdown guides and `docs/codes/`, GitHub Actions, Python
(`v5-tooling.md` §7 "Repo tooling"). What the milestone build already changed against v4, as facts of the two trees: tabs for
spaces, newer pinned tools plus selene, no wally, no `.luaurc` aliases, no vendored `typedefs/` (skill-cache
definitions instead), no `scripts/` runner and no CI. *(inferred)* v4's `edges` layer check and its CI gate have no
v5 counterpart yet; the next plan must either port them or name a replacement.

## 4. Lessons

One line each: what, cause, where the next plan prevents it. "Plan" means the next build plan; "done-check" a
unit's done-when list. Review ids are `m1-code.md`'s; fix ids `m1-plan.md` §7.

### 4.1 The milestone 1 fix list and the findings behind it

Review: 1 blocking, 9 major, 9 minor, 5 taste, all missed by a clean 242-test suite (`m1-code.md:9-18`).

| Fix | Finding | What and cause | Prevent in the plan |
|---|---|---|---|
| A1, C5, B1 | B1 | 3 bytes decoded to 4.2 M tables: the design bounded bits, never decoded elements; zero-bit elements and mode-0 columns make counts free (`m1-code.md:24-54`) | decode element budget and W in the wire/planner specs from the start (now `v5.md` §4.8 rule 10); hostile-decode done-check per unit |
| B1 | M3 | nested optionals, optional array elements and map values gave second encodings and lost pairs; "allowed everywhere" was a design gap; `gen.luau` never generated absent elements (`m1-code.md:106-132`) | `optionalPlacement` is design now; generators must cover every shape the format accepts |
| A2, C6 | M1 | `t.number(0, 0.3, 0.1)` top code decoded above `max`, so its re-encode raised; float stepping; no idempotence test | exhaustive idempotence specs in the quantizer unit's done-check |
| A3, C7 | M2 | 511 non-canonical direction codes at 8 bits; the fold zeroes a sign; the design claimed "idempotent by construction" | canonical = fixed point of E, checked; lead later required an iterating encoder (`m1-plan.md:685-686`), so C7 waited on A |
| A5, C8 | M9 | §3.3 said exhaustive idempotence tests existed; none did; round trips started from encoder output only | done-checks must test decoder-accepted input, not only encoder output |
| C1 | M4 | instance widths and rule 9 used `#list`, which is any border of an array with holes | chunk count from the header (`Chunk { list, offset, count }`) fixed in the codec unit's interface |
| C2 | M5 | encoding without `collect` wrote bytes the receiver refuses; correctness hung on call order | read-only encode, unlisted instance = `internal` |
| C4 | M6 | rollback partial: raises left bits, refusals left instances listed | one `pcall` per public encode; measured 0.1–0.3 µs per encode (`v5-changes.md` 3.4 §4.2 row) |
| A4, A9 | M7 | EG decode 84–105 ns against the design's 35–58: a cross-module call per value; bench predated final code | batched reader with a numeric threshold in the done-check; bench at HEAD |
| C3 | M8 | `Run.collect` encoded the whole run to find instances (48% of encode) | visitor over instance leaves (3.4% of encode, `v5-changes.md` 3.4 §4.2 row) |
| C9 | m1 | checked rotation decode built every `CFrame` twice | the check returns the value |
| A7 | m2 | two calls per field read or write (inliner cost limits) | inline hot bodies; record `p7` numbers |
| B2, C11 | m3 | IR types looser than the IR; casts, `fieldsOf`, `rotationBitsOf`, narrowing asserts | IR aliases per codec kind in the IR spec |
| B3 | m4 | a record field named `_value` inferred as a codec | brand `["[Lync] value"]` |
| A6, B4, C13 | m5 | helpers and constants duplicated across the three parallel units, in two idioms | a shared lowest-layer module (`wire/limits.luau`) owned before parallel units start |
| B5, C10 | m6 | open kind dispatch; the planned `never`/`Complete` fix is a type error on the old solver | replaced by one kind-coverage spec per half (`m1-plan.md:679-683`); plans must not prescribe solver-specific typing |
| B6 | m7 | `Fail.show` printed 17 digits (`got 0.34999999999999998`) | `tostring` for non-integers |
| B7 | m8 | Lync's source prefix had no separator, so `…Packages.LyncNet` was skipped | separator in the pattern |
| B11 | m9 | sizes spec checked the planner against a second model | encode with the real encoder (20,000 messages per definition; 17.8 s of the default run, **rerun**) |
| A8, B4, C12 | t1 | single-caller parameters and test seams in production signatures (`_lo`, `maxSteps`, `atOf`) | — |
| B8 | t2 | `Fail` dropped `got nil` | `Fail.NONE` sentinel |
| B9 | t3 | two conventions (0 vs nil) for options a kind doesn't take | nil |
| B10 | t4 | `CustomSpec` used `any`; `Target` lacked groups | typed; groups went to unit F, never built |
| — | t5 | §4.8 named mode and k as free; base and width are too | design text only |

### 4.2 Defects, workarounds and rulings during the build

- **Column inexact above n = 2^52.** The first row's residual was computed as `(code + half) % n − half` and decode
  added before wrapping, passing 2^53 (`git show 98e3ac2 -- src/wire/column.luau`). Unit C coded around it in its own
  `columns.luau` (centred intervals, 37 lines) and removed that after A's fix (`673d3e0`). The plan already listed
  n = 2^53 in A's property (`m1-plan.md:380`). Prevent: a dependency bug stops the dependent unit (builder rule 4);
  exactness vectors at n = 2^53 in A's done-check.
- **`t.rotation` not idempotent** (f32 near-ties): design 3.2 added a canonical check, then the lead replaced it
  after C's measurement with "fixed point or lower 2-cycle member", encoder iterating ≤ 4 steps, `internal` past it
  (`m1-plan.md:559-574`). Prevent: canonical rules proven by a prover before the codec unit.
- **`t.vector3` bounds that are not f32 values**: new tolerance rule and `vectorStep` code mid-milestone
  (`m1-plan.md:575-582`).
- **Typing realities**: `types.luau` had to be `--!nocheck` (the plan said `--!strict`); `{ read from }` and
  `index<…>` side selection, because a type-function selector crashed luau-analyze (exit 139) and the old solver
  widened literals (`m1-plan.md:535-537`).
- **Codes added by builders**: `notADefinition` (planned as `paramRange`), interpretations of `duplicateName`,
  `nameLength`, `mapKey`, `newestWidth`, then `vectorStep`, `internal`, `elementsTooMany`, `zeroWidthElement`,
  `optionalPlacement` (`m1-plan.md:537-545`, `:578`, `:647`). Registry ended at 50 codes: 21 declaration, 4 caller,
  17 fact, 5 outcome, 2 fault, 1 internal (front matter of `f1fbfd7:docs/codes/*.md`); 3.5 counts 53
  (`v5-changes.md` 3.5 decision 10).
- **Worst cases**: planner had to bound column blocks, not only rows (`m1-plan.md:543`); W for answers =
  1 + E(reply) (`:684`).
- **Byte-exact registry examples**: the lead ruled each page's `example` is the trigger's real output, compared byte
  for byte (`m1-plan.md:544-545`); this forced unit B's rework commit `1954821`.
- **Interfaces moved after being "fixed"**: `root` became a required parameter, and the lead had to edit two calls in
  B's files (`m1-plan.md:687-690`); `Facts.new` gained `counters` (`m2-plan.md:488-489`); frame kinds became five,
  `Control.Rekey` a record, untagged `HELLO` read by the caller (`m2-plan.md:498-502`).
- **`Instances.count` = committed encodes** means collecting several rows before encoding any drops later rows'
  instances on one refusal; the lead ruled F must never collect ahead (`m2-plan.md:494-496`). F's
  `encodeRequests` collects every row first (`f1fbfd7:src/sched/outbox.luau:313-336`); *(inferred)* the request chunk
  writes its instance count before the rows, so the ruling and the format conflict.
- **Client allowance**: D's fuzz needed a client bound; ruled 4,194,304 elements "so a zero-bit-row count can't hang
  a client" (`m2-plan.md:503-504`); later measured at 57–190 ms per such frame interpreted (`v5-3.6-inputs.md:126`).
- **Registry deferral**: E's lint could not check ten codes F raises, so `RAISED_BY_UNIT_F` postponed them
  (`f1fbfd7:test/diag/registry.spec.luau:64-75`); F never emptied it.
- **Toolchain**: selene's roblox std could not be generated behind the proxy (`m1-plan.md:530-531`); the Luau CLI has
  no Roblox types, so benchmarked code and the rotation bench use stand-ins (`m1-plan.md:96-97`,
  `test/codec/rotation.bench.luau` header).
- **Wording the audit later banned** (`simplifications.md` #1, #2, #25): `Net.HONEST`, test names "honest frames",
  "Hostile frames", `local attacker`, registry Fix lines "If honest players reach it" and a six-word
  `JUDGEMENT_WORDS` list scanning examples only (`registry.spec.luau:50`).
- **Evidence and triggers the audit found vague in the code** (`simplifications.md` #3, #7, #16, #17, #18, #24):
  `overBudget` evidence can't tell frame from byte bucket (`f1fbfd7:src/session/inbound.luau:981`); planner lets
  `burst` default to 2000 past its 1–1000 range (`planner.luau:932-934`); `decoderRaised` reported once per runtime
  window (`inbound.luau:561-575`); `missedFlush` "once" and evidence `frames` counting steps
  (`scheduler.luau:60-73`); `sendDropped` `queue` = 1 for a send never queued; constant evidence (`desync` 8,
  `remotesMissing` 10, `scheduler.luau:57`).

### 4.3 Observed at `f1fbfd7`, never reviewed (unit F's code and cross-module constants)

- Protocol constants have no single home: `TAG_BYTES = 2` in `transport/frame.luau:65`, `transport/tag.luau:25`
  and `session/inbound.luau:131`; slot/epoch/outcome widths in `sched/outbox.luau:80-82`, `inbound.luau:125-128`
  and `test/support/frame.luau:38-40`. The 32-bit tag (3.5) therefore touches three source files. Prevent: one
  constants module per `v5.md` §4.9, owned by the first unit.
- Encode-at-call plus column blocks: the outbox decodes every payload of a run of ≥ `MIN_ROWS` messages or with
  instances and re-encodes it at flush (`outbox.luau:17-18` header, `:280-290`, `:362-372`), and ignores the decode
  rule (`:288-289`). No design text specifies this. *(inferred)* cost per such message is one extra decode and encode.
- Control messages take effect mid-decode: a `HELLO` is handled and a `REKEY-ACK` switches the key
  (`inbound.luau:365`, `:376`) before later chunks of the frame pass; a frame refused afterwards keeps those effects
  *(inferred)*. The rule comes from `v5-changes.md` 3.1 M3.
- The client records `malformed` facts for its own decode refusals other than rule 10 (`inbound.luau:1045-1071`);
  draft 3.5 treats client decoder refusals as `refusedFrames` (`simplifications.md` #6, `v5-changes.md` 3.5 #6)
  *(inferred mismatch)*.
- The client flush keeps the remainder (`scheduler.luau:88-90`), which draft 3.6 now asks for
  (`v5-3.6-inputs.md:144`); the design text then read "since the last flush". The code was right, the text wrong.
- The fuzz spec's header still says a client's budget "is unlimited" (`test/transport/mutation.spec.luau:12-13`),
  stale after the 4,194,304 ruling.
- Unit F's modules type-error on both solvers and have no tests (§1).

### 4.4 What the plans got wrong about unit size, ordering and ownership

- **Unit F was the whole runtime.** It owned five session files, three sched files, `src/api/*`, `init.luau`, four
  test directories, view typing and a benchmark (`m2-plan.md:302`), with a done-check of 10 flows, validators,
  caller errors, 4 unmodified-client suites, 5 single-cause runs and about 30 modified-client cases
  (`:342-363`, `:399-441`). It stopped mid-build with 3,836 lines, no tests and type errors, `src/api` not started
  (commit `f1fbfd7` "unit F stopped mid-build"; ledger `:41`, `:48`).
- **The plan said D and E start at once; D started after milestone 1 closed** (`m2-plan.md:300` vs commit
  `20b1bee` 11:28:52), and only E ran in parallel with the milestone 1 review and fixes.
- **Review after the units, not per unit.** The review ran on milestone 1's finished code (`07b2ed3`); its 24
  findings then reopened all three units at once while E edited `src/diag/` (`m1-code.md:14-16`), which forced a
  routing rule: B may touch only `fail.luau`; new codes appended after E (`m1-plan.md:625-627`).
- **Ownership moved mid-build**: `test/golden/index.json` A → C (`m1-plan.md:528-529`); `test/support/frame.luau`
  C → D (`m2-plan.md:505`); `test/session/buckets.spec.luau` to E (`:493`); the lead edited B's files (`m1-plan.md:689`).
  `diag/codes.luau` and `docs/codes/` were written by B, then E, then F.
- **Start conditions hid dependencies**: C started "when A's bits, ints and column pass their own tests"
  (`m1-plan.md:368`), yet A's column was inexact and C worked around it; C7 waited on A's direction encoder; D's
  decode work waited on C1 (`m2-plan.md:300`).
- **Design changed under running units**: drafts 3.2 (09:57) and 3.3 (10:53) landed while units were active; 3.2's
  rotation rule was itself superseded during C's work (`m1-plan.md:565`).
- **Plans prescribed what the toolchain could not do**: `never`-closed dispatch (old solver), `--!strict` types,
  selene's roblox std, `bench/rows.luau` on the CLI (§4.2).
- **Seams planned across units never met**: E built `world.luau` against a stub `Runtime.new` for F to plug in
  (`m2-plan.md:305`); F never did, so the world was never exercised by a runtime.

## 5. Reusable as is, reusable with changes, discard

The code was built against draft 3.2–3.4 (`m1-plan.md:10`, `m2-plan.md:10`). Changes since then that touch it:

**Draft 3.5** (`v5-changes.md`, line of each row):
- **X1** tag 32 bits; G4, G5, G8 gain two bytes (`:548`). **X2** `tag.cover` default 16,384 (`:549`).
- **X3** `overBudget` → `overFrameBudget`, `overByteBudget`, `overElementBudget` (`:505`).
- **X4** `limit.perSecond` (0, 1000], `burst` default min(1000, max(1, ⌈perSecond⌉)), `priority` real 0.001–1000,
  `reliableRate` real (`:509`); configure option types and ranges (`:510`).
- **X5** sixth outcome `limited` (`:512`, `:571`). **X6** one native report per (code, definition) per window
  (`:518`). **X7** `missedFlush` once per wait, evidence `steps` (`:519`). **X8** `sendDropped` evidence `cause`
  1–4, `lane` dropped (`:520`). **X9** `desync` `sinceRekey`, `remotesMissing` no evidence (`:526`).
- **X10** "unmodified client" vocabulary; the judging-word rule over code, evidence and counter names, messages and
  pages; `honest*` banned; `Net.HONEST` → `Net.DEFAULT` (`:503-504`). **X11** client-stated `reported*` codes (`:508`).
- **X12** downstream frames split before 4,194,304 elements (`:570`); client counter `refusedFrames` (`:574`);
  `callerProbe.maxPerSecond` 1–63 (`:579`); `clock.beacon` integer tenths (`:517`). 53 codes for milestones 1–2.

**Draft 3.6 inputs** (`v5-3.6-inputs.md`; being decided, so each is "proposed"):
- **Y1** per-server layout (`layout.vary`): field order, M3 code offsets and tag constants vary on the runtime path;
  the planner takes layout seeds (`:56`, `:60`, `:192`; `v5.md` §2 in progress); enum/variant indices by offset
  (`:216`); M3's column first-row rule becomes a protocol constant (`:89`).
- **Y2** `HELLO` carries `buildId` (`:61`), `weaveHash` (`:105`); `WELCOME` gains `layout` u2 and two
  `callerProbe` bits (`:107-108`); `REPORT` loses `sourceUnlisted` (`:109`); `RATE` gains `delay` u8 (`:110`); key
  and permutation seed derived from a nonce by HalfSipHash-2-4 (`:93`).
- **Y3** tag: caller-source bit in the lane byte (`:96`), per-player mask (`:95`), rotation amounts and rounds from a
  vetted pool, `build.tagRounds` (`:213-214`, conflict `:377`).
- **Y4** upstream reliable header `ack rcv:u8` (`:81`). **Y5** `REKEY` one pending per player, `REKEY-ACK`
  repeated, the 60 s constant removed (`:98-99`, `:130`).
- **Y6** codec methods `:claim()`, `:input()`, visibility modifiers; hash input type 26 and a visibility byte per
  field (`:66-67`, `:117-118`); options `perceived`, `sealed` (`:71-72`, `:119-120`); site and trap ids in the up
  space (`:111-112`); offset and string-reference decode rules (`:124-125`).
- **Y7** server request results gain `roundTrip`, `pingAtSend`, `pingAtAnswer`, `minPing` (`:76`).
- **Y8** client `FireServer` captured once per remote (`:80`). **Y9** due `REPORT`/`BEACON` are pending data
  (`:145-146`). **Y10** inbound steps: hash bound, checks, claims, telemetry, site-id mapping (`:152-158`).
- **Y11** new codes (`:165-169`), counters (`:181-186`), configure options (`:192-193`); example schema gains
  `:claim()` and `:input()` (`:73`). **Y12** the interpreter is kept as built (`:53`; `v5.md` §2 decision, in
  progress).

| Module or helper | Verdict | Why (change keys) |
|---|---|---|
| `wire/bits`, `wire/ints`, `wire/limits` | as is | no change found; reviewed and fixed (A1, A4, A6, A7) |
| `wire/column` | as is, pending Y1 | exact to 2^53, measured; changes only if M3's first-row rule is "against 0" |
| `wire/quant` | as is | canonical encoders and predicates done (A2, A3); offsets (Y1) act on codes, not quantizers *(inferred)* |
| `wire/halfsiphash` | with changes | IVs are parameters already; rotation amounts and rounds from a pool are not (Y3) |
| `plan/dsl` | with changes | new methods and placement codes (Y6), limit ranges (X4) |
| `plan/ir` | with changes | fields for roles, visibility, `perceived`, `sealed`, layout, site/trap ids (Y1, Y6) |
| `plan/planner` | with changes | X4 ranges; layout seeds as input; id spaces with sites and traps; new declaration codes (Y1, Y6, Y11) |
| `plan/serialize` | with changes | type 26, visibility byte, `perceived`, `sealed`, serialization version; G6 changes (Y6) |
| `types.luau` | with changes | `Failure` gains `limited` (X5); result timing fields (Y7); new codec methods (Y6) |
| `init.luau` | discard | 57-line milestone 1 surface; the runtime API was never built |
| `codec/leaves`, `rows`, `columns`, `run` | with changes | form kept (Y12); offsets on bounded codes, per-layout field order, new decode rules (Y1, Y6) |
| `diag/fail`, `diag/console` | as is | fixed (B6–B8); console text constant per code; names follow the 3.6 naming audit if it renames codes |
| `diag/codes` + `docs/codes/*.md` (50) | with changes | X3, X5, X7–X11, Y11; every page's cause and Fix lines reworded (X10) |
| `diag/facts`, `diag/counters` | with changes | mechanism kept; evidence orders (X3, X8, X9), new counters (X12, Y11) |
| `host/host` | as is | seam unchanged by any item found |
| `host/roblox` | with changes | `FireServer` capture (Y8); still type-check-only |
| `transport/seq`, `transport/toc`, `session/replay`, `session/buckets` | as is | no change found |
| `session/permutation` | as is | Fisher–Yates unchanged; the seed derivation (Y2) lives in the handshake; PERM vector unchanged |
| `transport/header` | with changes | `rcv:u8` (Y4) |
| `transport/control` | with changes | `HELLO`, `WELCOME`, `REPORT`, `RATE`, `REKEY` rows (Y2, Y5, X12) |
| `transport/frame` | with changes | 4-byte tag (X1), element split (X12), header sizes (Y4) |
| `transport/tag` | with changes (near rewrite) | 32 bits (X1), caller bit, mask, derived key, pooled constants (Y2, Y3); 113 lines |
| `session/state`, `connection`, `handshake`, `requests`, `inbound`; `sched/outbox` | discard; read as reference | never tested, type errors on both solvers (§1), and changed by X1–X3, X5, X6, X8, X9, Y2, Y4, Y5, Y7, Y9, Y10 |
| `sched/scheduler`, `sched/ticks` | with changes | clean types, untested; X7, X9, Y9; flush carry already right (§4.3) |
| `test/run.luau`, `support/check`, `support/prop`, `support/golden` | as is | small, generic; `getfenv` stays out of `src` |
| `support/gen` | with changes | new codec methods and visibility (Y6); offsets for nonzero layouts (Y1) |
| `support/frame` | with changes | `arena` schema (Y11 example), outcome comment `0 value, 1 rejected, 2 unanswered` lacks `limited` (X5) |
| `support/net` | with changes | rename `Net.HONEST` → `Net.DEFAULT` (X10); model is what `v5.md` §9 now cites |
| `support/world` | with changes | sound, but never driven by a real runtime; `world.spec` names (`local attacker`, X10) |
| `transport/frames.luau` (test decoder) | with changes | X1, Y4, Y2 rows |
| `golden/index.json` + `.bin` | with changes | G1–G3, G9, G11, PERM, `Q-*` stand; G4, G5, G6, G7, G8, G10 change, G4c/DERIVE/W1/W2 new (`v5.md` §4.10, in progress) |
| `golden.spec`, `diag/registry.spec` | with changes | new vectors; registry: the rule replaces `JUDGEMENT_WORDS`, empty `RAISED_BY_UNIT_F` (X10) |
| codec, wire, transport mutation/fuzz specs | with changes | names by origin and rule (X10); tag width (X1) |
| `test/types/*` | with changes | `Failure` with `limited` (X5); request typing (Y7) |
| `quant.cases`, `quant.golden`, `halfsiphash.vectors`, `rotation_full`, `min_rows`, `bench/column.bench`, `rotation.bench` | as is | independent of every change found |

## 6. Unit sizing evidence

Durations are wall-clock between the lead's commits (the "Track …" commit that launched or recorded a unit, and the
unit's result commit), from `git log c16fb47..f1fbfd7`; no duration is recorded anywhere else. Test counts are the
ledger's (`f1fbfd7:.data/docs/agents.md:35-41`) unless marked derived. Lines are `src` lines at `f1fbfd7`.

| Unit | Scope | Files (src lines) | Tests | Duration | Outcome |
|---|---|---|---|---|---|
| M1 A | scaffolding, `wire/*`, HalfSipHash, runner and helpers, bench | 5 wire files (+`limits` later), `test/wire`, `test/support/{check,prop,golden}`, `bench/` (1,875) | 48 at done | 08:45:53 → 09:17:49, 32 min | done; Column exactness fixed after C hit it (09:56); fix list A1–A9 11 min; direction encoder and `LYNC_FULL` split to 11:13 |
| M1 B | DSL, planner, IR, hash, diag registry and pages (18 byte-exact examples), types, typing proofs | `plan/*`, `diag/{codes,fail}`, `types`, `init`, `docs/codes` (≈3,730) | 146 at done | 08:45:53 → 09:24:47, 39 min | done; rework commit 7 min later for three lead rulings (`1954821`); `vectorStep`, `internal` added; fix list 14 min, B5 replaced by a kind-coverage spec |
| M1 C | interpreter, column flattening, goldens G2–G8, `columnMinRows` | `codec/*`, `test/{codec,golden}`, `support/{gen,frame}` (3,312) | suite at 227 after the workaround's removal | 09:25:09 → 09:53:38, 28 min | done; canonical rotation rework 10:04 → 10:29 after design 3.2; fix list C1–C13 35 min (10:53:52 → 11:28:28) |
| M1 review | correctness, hostile decode (fuzz), cost, types, style | 14 probes | — | 10:29:39 → 10:48:57, 19 min | 24 findings, all accepted or changed (`v5-changes.md` 3.2→3.3) |
| M2 E | `Host` seams, facts, counters, console, buckets, world and network | `host/*`, `diag/{facts,counters,console}`, `session/buckets`, `support/{world,net}` (1,318 src + 986 support) | 52 derived (host 25, console 6, counters 5, facts 12, buckets 4); 27 codes | 10:34:43 → 11:01:35, 27 min | done; follow-up 2 min later (facts count themselves) |
| M2 D | frames, headers, toc, control, tag, seq, replay, permutation, G5/G7/G10/G11/PERM | `transport/*`, `session/{permutation,replay}`, `Bits.copy` (1,540) | 430 suite total; 68 derived (transport 54, permutation 4, replay 5, golden 5) | 11:28:52 → 11:58:36, 30 min | done, fuzzed |
| M2 F | session rest, sched, api, init, world suites, view typing, bench | 8 files written (3,836); `src/api` not started | 0 | 11:59:02 → 12:26:01, 27 min | **stopped mid-build** when the author paused milestone work (ledger `:48`); type errors in 4 files |

Totals: milestone 1 took 08:45 → 11:28 (2 h 43 min) for 362 tests, including a review and a fix round touching every
unit; milestone 2's D and E took about 30 min each; F did not finish. No unit was redone after a model fallback (the
ledger's fallback rule, `agents.md:13-14`, names none for builders).

What worked *(inferred from the table)*: units of about 1,300–3,600 `src` lines, one layer or two adjacent ones, whose
done-check is byte-exact (golden vectors, reference hash vectors, G6) or a measured threshold, finished in 27–39
minutes. What failed: a unit spanning four layers with a done-check made of end-to-end world scenarios, whose
dependencies (E's world, D's transport) were themselves fresh. What caused rework: design rulings landing during a
unit (3.2, 3.3), an upstream defect worked around downstream, and a review run after all three units instead of per
unit.

## Open questions

- Which 3.6 proposals land (Y1–Y11 are proposals in `v5-3.6-inputs.md`); the verdicts in §5 for `column`, `tag`,
  `halfsiphash`, `control`, `header` and the codec files depend on M3's first-row rule, the tag pool conflict
  (`v5-3.6-inputs.md:377`) and `rcv:u8`'s milestone (`:481`, cross-unit question 3).
- Whether the next plan keeps encode-at-call (caller errors at the caller's line) with a decode-and-re-encode at
  flush for column runs, or specifies another mechanism; the design is silent (§4.3).
- Whether control messages may take effect before the rest of their frame passes, given `REKEY-ACK` switches keys
  mid-decode (§4.3).
- Whether client decode refusals other than rule 10 are facts (`malformed`) or only `refusedFrames` (§4.3).
- How request chunks reconcile the instance count written before the rows with "never collect ahead" (§4.2).
- StyLua and selene status of the `f1fbfd7` tree: never recorded, not rerun here; and whether selene's roblox std can
  be generated in this environment now.
- Where protocol constants live (one module per `v5.md` §4.9?) and who owns it, so the 32-bit tag is a one-line change.
- Whether a layer check (v4's `edges`) and a CI workflow are in scope for the next build's first unit.
- Unit F's real cost: no measured duration exists for any runtime unit that finished, so the split of F's scope
  (session, sched, api, world suites) has no direct evidence beyond D and E.
