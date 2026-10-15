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
- [ ] 4. Lessons
- [ ] 5. Reusable as is, with changes, discard
- [ ] 6. Unit sizing evidence
- [ ] Open questions

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
`getfenv(0)` before any require (`:39-45`, `:76`), the only `getfenv` in the tree. Env switches: `LYNC_SEED=<n>` (replay),
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
