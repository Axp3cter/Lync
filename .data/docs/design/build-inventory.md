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
- [ ] 2. Test harness
- [ ] 3. Tooling and config
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
| `session/state` | 507 | F | the runtime record and its constants; `answer`/`control` callbacks so session can queue without requiring sched (`:16-17` of its header) | `Limit Config Payload Request Answering Message Definition Namespace Waiting Held Connection Group Target(=any) Mode Runtime`; `ALL EMPTY_PAYLOAD VERSION BUILD_SEED … count fact` | buckets, diag/console, transport/control, diag/counters, diag/facts, transport/frame, host/host, plan/ir, replay | `m2-plan.md` §2 |
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
`v5.md` §2's layer list (`v5.md:94-95`, "session (handshake, tag, acks, requests) → sched (flushing, ticks,
budgets)"): the tag is `transport/tag.luau` and the buckets are `session/buckets.luau` (`m2-plan.md` §3.3, §3.4).
No check enforces the layer rule (no test or script scans requires) *(inferred from a search of `test/`)*.

Type check **(rerun)**: `luau-lsp analyze` on `src` is clean on both solvers for every unit A–E file. Unit F's files
are not: new solver 6 errors in `sched/outbox`, 14 in `session/requests`, 6 in `session/state`, 1 in
`session/inbound`; old solver 2 each in `outbox`, `requests`, `inbound` (for example
`f1fbfd7:src/session/requests.luau:160` "Function only returns 1 value, but 2 are required"). Every F module loads
under Lune; `host/roblox` cannot (it calls `game:GetService` at load).
