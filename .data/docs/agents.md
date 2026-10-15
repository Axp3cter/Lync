# Agent ledger

Every agent run in v5 work: its role, what context it holds, what it produced, and whether to reuse it.

**Reusing an agent.** Ids are valid only inside the session that started them. Inside that session, send a
follow-up to the id (SendMessage) and the agent resumes with its full context. In a later session, start a
fresh agent with the same role and point it at the agent's output files.

**Role definitions** live in `.claude/agents/`: scout, researcher, critic, prover, builder, architect. Until a
session restarts after a definition is added, run the role as `general-purpose` with the prompt
"First read `.claude/agents/<role>.md` and act in that role."

**Model check.** After an agent finishes, check its transcript for model fallbacks:
`grep -o '"model":"[^"]*"' <task>.output | sort | uniq -c`. Any output written after a fallback gets redone.

## Session 01DGtKn13NLZZAhYhziWPm2o (2026-10-15)

| Id | Role | Task and context held | Output | Status |
|---|---|---|---|---|
| `a39dd09252a3e0012` | scout | v4 source and inventory: API, codecs, wire, perf, typing, defects | `research/v4.md` | done; reusable for v4 questions |
| `a24b607cf1ec2e284` | scout | the first v5 attempt: notes, spec, harness, ApiTypes and Determinism probes | `research/v5-attempt.md` | done; reusable for attempt questions |
| `a02c23c2cb4fd10d2` | researcher | competitors (Blink, Zap, etc.), Roblox wire facts, Luau runtime, typing on both solvers, tooling ecosystem | `research/landscape.md`, `probes/landscape/` | done; reusable for ecosystem and competitor questions |
| `ac2643bd70dc5e6a4` | prover | type inference T1–T7 (codecs, unions, enums, patches, views, old solver) and codegen speed P1–P2 | `probes/typing-and-codegen/RESULTS.md` | done; **first choice for type-system proofs** |
| `a22568e1c5e5b2791` | researcher | attacker model, the potassium executor API, AAA anti-cheat (VALORANT fog of war, Call of Duty hallucinations, VACnet, lag compensation). Its first brief was stopped by a safety check; benchmarks were cancelled | `research/anticheat-design.md`, `probes/anticheat-design/` | done; reusable for anti-cheat design (defensive framing only) |
| `aeaae679cfec700fe` | researcher | runtime wire integrity: keyed tags, replay window, shuffling, traps, timing, the Suspicion model, knobs | `research/client-security.md`, `probes/client-security/` | done; reusable for integrity and signal questions |
| `aafffcfeff18c5314` | researcher | build-time tooling, first run. **Fell back to Opus 4.8** after a cyber-policy refusal; its brief was replaced | none kept | **do not reuse** |
| `a50bedf3e2bec28b1` | researcher | build pipeline: Rojo, darklua, luau-lsp, roblox-ts, Lute, Lune, mlua, Studio plugin APIs, Open Cloud, `lync.toml`, Creator Store rules | `research/client-security-build.md`, `probes/client-security-build/` | done; **first choice for tooling, CLI and plugin work** |
| `a48e1c21d3d3f5ba8` | researcher | encoding: engine zstd evidence, column coder, integer and float codes, quantization, interning, entropy coding, traffic models | `research/compression.md`, `probes/compression/` (incl. `studio/` probe) | done; **first choice for wire-format work** |
| `a10c21d6f462379ea` | researcher | state sync: notify model, acks, priority accumulators, budgets, interest management, inputs, time, modern engines | `research/state-sync.md`, `probes/state-sync/` | done; **first choice for replication and scheduling** |
| `a56677e25c2c92fb5` | critic | broad review of design draft 1: API beauty, typing (probes), hot path, research consistency, gaps | `reviews/v5-design-1.md`, `probes/review-1/` | draft 1 done (3 blocking, 13 major, 11 minor, 4 taste); draft 2 done → `reviews/v5-design-2.md` (3 blocking, 12 major, 11 minor, 2 taste); draft 3 readiness done → `reviews/v5-design-3.md` (0 blocking, 7 major, 5 minor; golden frames proposed); reusable for design and typing review |
| `a00f8d63b9b01f794` | critic | redundancy and inefficiency in design draft 1, with measurements | `reviews/v5-design-1-redundancy.md`, `probes/review-redundancy/` | draft 1 done (1 blocking, 8 major, 10 minor, 1 taste); draft 2 done → `reviews/v5-design-2-redundancy.md` (1 blocking, 2 major, 9 minor, 3 taste); reusable for cost and redundancy review |
| `a3deaff2845a787e5` | architect | design draft 2 from both draft-1 reviews; holds the design, both reviews and the research sections they cite | `design/v5.md` (partial draft 2, commit d979d52), `probes/design-2/` | **cancelled** by an interrupt; cannot be resumed |
| `a43f3fd7d64db5725` | architect | finishes draft 2 from the partial file; both draft-1 reviews; decisions: facts not verdicts, rotation and permutation kept | `design/v5.md` (draft 2), `design/v5-changes.md`, `probes/design-2/` | draft 2 done (51 findings: 30 accepted, 20 changed, 1 deferred); draft 3 done (43 findings: 29 accepted, 14 changed; core 878 lines + `v5-collections`, `v5-integrity`, `v5-tooling`, `v5-extensions`); draft 3.3 and the `m1-plan.md` §7 fix list done (24 findings: 23 accepted, 1 changed); reusable for design fixes |
| `a0ea34d7fc5c8bfc1` | researcher | diagnostics: Luau/Roblox error mechanics, error codes (rustc, TS, Node, SQLSTATE, gRPC, RFC 9457), message design, failure taxonomy and channels, observer events, metrics, CLI/SARIF/LSP output, competitors, abuse, hot-path cost | `research/diagnostics.md`, `probes/diagnostics/` | done; **first choice for errors, codes and reporting** (Mirror, FishNet, Photon not covered) |
| `a36e8d96b67387fd7` | builder | milestone 1 unit A: scaffolding, `src/wire` (bits, ints, quantizers, column coder), HalfSipHash, test runner and helpers, benchmarks | `src/wire/`, `test/wire/`, `test/support/`, `bench/`, config files | done (48 tests; k search ≤ 2.44× k = 0 encode); A1–A9 and the canonical direction encoder done (63 wire tests); **running**: move million-sample specs behind a flag |
| `a0c447a56e69a6bc0` | builder | milestone 1 unit B: schema DSL, planner, IR, schema hash, diagnostics registry and code pages, typing proofs | `src/init.luau`, `src/types.luau`, `src/plan/`, `src/diag/`, `docs/codes/`, `test/{plan,diag,types}/` | done (146 tests; G6 exact; typing proofs pass; column-block worst case; byte-exact examples); done (sizes test from `MIN_ROWS`; 18 byte-exact examples); B1–B4, B6–B10 done; B11 waits on C6; **running**: B5 replaced by a kind-coverage test (§7.4) |
| `afa262a830e0db8b1` | builder | milestone 1 unit C: runtime interpreter, column integration, golden set G2–G8, `columnMinRows` | `src/codec/`, `test/codec/`, `test/golden/`, `test/support/{gen,frame}.luau` | done (G2–G4, G8 exact; `columnMinRows` = 3); workaround removed (227 tests); **running**: fix list §7.3 (C1–C13; C7 waits on A, C11 on B2) |
| `abc0b8963b21872e9` | critic | milestone 1 code review: correctness against the design, hostile decode input (fuzzing), hot-path cost, types, style, tests | `reviews/m1-code.md`, `probes/review-m1/` | done (1 blocking, 9 major, 9 minor, 5 taste; seeded fuzzer); reusable for code review |
| `a8d693323bb70d522` | builder | milestone 2 unit E: `Host` seams, facts, counters, console, buckets, simulated world and network model | `src/host/`, `src/diag/`, `docs/codes/`, `src/session/buckets.luau`, `test/support/{world,net}.luau`, `test/{host,diag}/` | done (27 codes; `Facts.new` takes `Counters`); reusable for host, diag and world work |

Paths are relative to `.data/docs/`, except builders' paths, which are relative to the repo root.

## Next

- Milestone 1 fixes: A (direction encoder), B and C running (`m1-plan.md` §7). Milestone 2: E done; D after the fixes; then F.
