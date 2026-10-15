# Agent ledger

Every agent run in v5 work: its role, what context it holds, what it produced, and whether to reuse it.

**Reusing an agent.** Ids are valid only inside the session that started them. Inside that session, send a
follow-up to the id (SendMessage) and the agent resumes with its full context. Earlier sessions' agents are not
listed; their work lives in the files under `research/`, `reviews/`, `design/` and `probes/`.

**Role definitions** live in `.claude/agents/`: scout, researcher, critic, prover, builder, architect. Until a
session restarts after a definition is added, run the role as `general-purpose` with the prompt
"First read `.claude/agents/<role>.md` and act in that role."

**Model check.** After an agent finishes, check its transcript for model fallbacks:
`grep -o '"model":"[^"]*"' <task>.output | sort | uniq -c`. Any output written after a fallback gets redone.

## Session 01HcPgd9HVKeKd9zYowMmdmt (2026-10-15)

Branch `claude/hopeful-edison-kwkdxt`. Task: reconsider every refused security decision with generation (the generated path: per-build, per-player shards) taken into account; re-derive runtime-path limits and costs instead of trusting them; build on the real tooling APIs.

| Id | Role | Task and context held | Output | Status |
|---|---|---|---|---|
| `adb93333f6c4648cf` | scout | all of `.data/docs` in full; every refused, dropped or undecided security measure, its reasons, what they assume, and whether each cited cost or limit was measured, derived or asserted | `research/security-refusals.md` | done (59 items: R1–R40 refused, D1–D4 deferred, U1–U15 undecided; full read; no fallback); free for follow-ups |
| `ae7b1fdfd83468cdb` | researcher | generation facts: obfuscation rules by channel, per-player code delivery, what a client reads from a shard, generated code vs Luau limits and native codegen, load cost, prior art | `research/generation-security.md`, `probes/generation-security/`; now `research/generation-methods.md` | facts done (no fallback), judged too generic by the author; **now the methods agent**: concrete generation methods in Lync's own pipeline |
| `ade0c89512482ae96` | researcher | API catalogue for security: Roblox engine (server, client), Studio plugin, Open Cloud, Lute, Lune, mlua, darklua, luau-lsp, rojo, Python, the executor API | `research/security-tooling.md`, `probes/security-tooling/` | done on the configured model after a fallback redo (19 claims changed or dropped); §2 (client side, unmodified client) not written after a classifier stop, see `client-security.md` §2.2; now on D1, D2, U8, U13, U15 → `research/interest-rewind.md` |
| `a7526dc18c6060de5` | architect | started on codecs in game scripts; stopped, since the architect integrates rather than designs | none | stopped; do not reuse |
| `a6d6d1502e0ad3c95` | researcher | codecs spread into game scripts: transform of the built place, typed API, call-site discovery, source maps, interaction with seed/rotation/tag; dual-purpose forms; re-derives the 5.0x bytecode figure | `research/codecs-in-scripts.md`, `probes/codecs-in-scripts/` | running |
| `ad69e26579bcfc07b` | prover | re-measures every performance figure used to refuse or narrow a security measure, plus generated cheaper forms | `probes/security-costs/RESULTS.md` | running |

Paths are relative to `.data/docs/`, except builders' paths, which are relative to the repo root.

## Next

- Built code removed at the author's request (in git at `f1fbfd7`, not on this remote; evidence data in
  `probes/build/`). Design at draft 3.5. No milestone work without the author's go-ahead.
- Security re-judgment in progress: the agents above find facts and designs; then an architect brings them
  together into draft 3.6; then a critic reviews it. Designing new mechanisms is research work, not the architect's.
- Author direction: nothing is deferred. Items the docs push to milestone 7 or leave undecided get designed now.
  No new agents beyond the five above; follow-ups go to an agent once it finishes its current task.
- Queue (ids → follow-up, from `research/security-refusals.md`):
  - `ade0c89512482ae96` (tooling): after its redo, D1 `interest` (per-viewer relevancy, build-time PVS bake,
    visibility classes U8, relevancy facts U13), D2 `rewind`, U15 streaming guidance, the PlayerGui variant timing
    rule (partial work in `probes/interest-rewind/` from the generation researcher); then D3 `checks` (`within`, `monotonic`, `maxTotal`, `:claim()`, U12 lint), D4
    `telemetry` (feature streams, `:aim()`, Roblox terms on off-platform data), U5 `foreignRemotes`, U6 core hash
    and manifest drift.
  - `ad69e26579bcfc07b` (prover): U1 captured `FireServer`, U2 tag rounds and per-build rotation amounts, U7
    `debug.info` caller attestation in the tag: cost and what each survives.
  - `a6d6d1502e0ad3c95` (codecs): U9 `Lync.derive`, U10 reaction floor on `:reactsTo`, U11 decoy-adjacent facts,
    U14 server-issued challenges, U3, U4 — after its current task.
  - R39 per-frame transform hook → `ad69e26579bcfc07b` (prover), cost of a hook slot; R40 Studio trap line → the architect.
- Author direction: codecs spread into game scripts can work. Reconsider it as a design
  problem, not a refusal: look for a form that serves two purposes at once (e.g. per-site code that is both faster
  and harder to isolate), transforming the built output rather than the developer's source if that removes the
  script-rewrite problems. If no such form holds up, say why plainly; that outcome is acceptable.
