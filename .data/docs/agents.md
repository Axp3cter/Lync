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
| `a56677e25c2c92fb5` | critic | broad review of design draft 1: API beauty, typing (probes), hot path, research consistency, gaps | `reviews/v5-design-1.md`, `probes/review-1/` | done (3 blocking, 13 major, 11 minor, 4 taste); reusable for design and typing review |
| `a00f8d63b9b01f794` | critic | redundancy and inefficiency in design draft 1, with measurements | `reviews/v5-design-1-redundancy.md`, `probes/review-redundancy/` | done (1 blocking, 8 major, 10 minor, 1 taste); reusable for cost and redundancy review |
| `a3deaff2845a787e5` | architect | design draft 2 from both draft-1 reviews; holds the design, both reviews and the research sections they cite | `design/v5.md` (partial draft 2, commit d979d52), `probes/design-2/` | **cancelled** by an interrupt; cannot be resumed |
| `a43f3fd7d64db5725` | architect | finishes draft 2 from the partial file; both draft-1 reviews; decisions: facts not verdicts, rotation and permutation kept | `design/v5.md` (draft 2), `design/v5-changes.md`, `probes/design-2/` | running |

Paths are relative to `.data/docs/`.

## Next

- Second critic pass on draft 2 if the change log warrants it, then milestone 1 (wire and codecs) with builders.
