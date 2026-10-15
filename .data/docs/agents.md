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
| `adb93333f6c4648cf` | scout | all of `.data/docs` in full; every refused, dropped or undecided security measure, its reasons, what they assume, and whether each cited cost or limit was measured, derived or asserted | `research/security-refusals.md` | done (59 items: R1–R40 refused, D1–D4 deferred, U1–U15 undecided; full read; no fallback); retired |
| `ae7b1fdfd83468cdb` | researcher | generation facts: obfuscation rules by channel, per-player delivery, what a client reads from a shard, Luau limits, load cost, prior art; then methods M1–M12 | `research/generation-security.md` (kept); `probes/generation-methods/` (kept, valid) | retired: facts brief judged too generic; its methods file was written after a model fallback and removed (copy in the lead's scratchpad, used only as a checklist) |
| `ade0c89512482ae96` | researcher | API catalogue for security (all surfaces); then `interest` (D1, U8, U13) | `research/security-tooling.md`, `probes/security-tooling/`; `research/interest-rewind.md` §1–§10, `probes/interest-rewind/` | done; catalogue redone after a fallback (§2 by another agent); interest on Opus 5.5, 11/11 sections; found the per-slot generation gap (`gen:u2` per add) and `decoyOutsideInterest`; retired |
| `a7526dc18c6060de5` | architect | started on codecs in game scripts; stopped, since the architect integrates rather than designs | none | stopped; do not reuse |
| `a6d6d1502e0ad3c95` | researcher | codecs spread into game scripts: transform of the built place, typed API, call-site discovery, source maps, interaction with seed/rotation/tag; dual-purpose forms; re-derives the 5.0x bytecode figure | `research/codecs-in-scripts.md`, `probes/codecs-in-scripts/` | done on Opus 5.5: weaving the built place works end to end (Lune round trip); 5.0x is one shape's worst case (1.03–3.0x realistic, 0.43x with dead encoders dropped); woven sites 1.3–3.5x faster on the client; dual purpose holds via site-bound wire ids; found a reachability gap (namespace iteration); retired |
| `ad69e26579bcfc07b` | prover | re-measures every performance figure used to refuse or narrow a security measure, plus generated cheaper forms | `probes/security-costs/RESULTS.md` | running |
| `a5072800c2daf5fdc` | researcher | **the methods agent**: concrete generation methods in Lync's pipeline; re-checks M1–M12 against their probes and goes further (per-player tag binding, generated traps/decoys/canaries, runtime-path per-session parameters) | `research/generation-methods.md`, `probes/generation-methods/` | running |
| `a6b292c4df871349d` | researcher | client shard self-checks: finishes `security-tooling.md` §2; U1 captured `FireServer`, U2 tag rounds and rotation amounts, U7 caller information in the tag | `research/security-tooling.md` §2, `research/client-self-checks.md`, `probes/client-self-checks/` | running |
| `a0f684951116653fa` | researcher | unit 2: `rewind` (D2), U15 streaming guidance, the PlayerGui variant timing rule | append to `research/interest-rewind.md`, `probes/interest-rewind/` | running |
| `aaaa767102bda45cc` | researcher | unit 3: `checks` (D3) and the free-form field lint (U12) | `research/checks-telemetry.md`, `probes/checks-telemetry/` | running |

Paths are relative to `.data/docs/`, except builders' paths, which are relative to the repo root.

## Next

- Built code removed at the author's request (in git at `f1fbfd7`, not on this remote; evidence data in
  `probes/build/`). Design at draft 3.5. No milestone work without the author's go-ahead.
- Security re-judgment in progress: the agents above find facts and designs; then an architect brings them
  together into draft 3.6; then a critic reviews it. Designing new mechanisms is research work, not the architect's.
- Author direction: nothing is deferred. Items the docs push to milestone 7 or leave undecided get designed now.
  No new agents beyond the five above; follow-ups go to an agent once it finishes its current task.
- Process rule: every agent writes a header and a checklist first, then one section per edit, ticking it; an
  interrupted section is marked "not written" and the agent continues. Briefs are worded around what Lync builds.
- Generation-methods units (the methods agent and unit 6) must come from Opus 5.5 only: launched with the Opus
  model, transcript checked on return, and any section written on another model redone as its own unit.
- Units, smallest first, each to a fresh agent as a slot frees (at most five running). Fallbacks count as
  interruptions: a unit written after one is redone as its own unit.
  1. ~~`interest`~~ done.
  2. `rewind`: D2, U15, the PlayerGui variant timing rule → append to `research/interest-rewind.md` (on `a0f684951116653fa`).
  3. `checks`: D3, U12 → `research/checks-telemetry.md` (on `aaaa767102bda45cc`).
  4. `telemetry`: D4, with Roblox's terms on off-platform data → append to `research/checks-telemetry.md`.
     Note for units 3–4: `probes/checks-telemetry/checks_cost.luau` exists; its "atom copy" line divides by N but runs N/10 copies (real figure 10x the printed one).
  5. `build checks`: U5 `foreignRemotes` and `dynamicAccess`, U6 core hash and manifest drift → `research/build-checks.md`.
  6. `methods, part 2`: per-player tag binding, generated traps/decoys/canaries, runtime-path per-session
     parameters, composition with codecs-in-scripts → append to `research/generation-methods.md`.
  7. `server facts A`: U9 `Lync.derive`, U10 reaction floor on `:reactsTo` → `research/server-facts.md`.
  8. `server facts B`: U11 decoy-adjacent facts, U14 server-issued challenges → append to `research/server-facts.md`.
  9. `clock and timing`: U3 beacon window rules, U4 `roundTrip`/`ping` → append to `research/server-facts.md`.
  10. Architect, per area once its research is in: integrity (`v5-integrity.md`), wire and ids (`v5.md` §4),
      tooling (`v5-tooling.md`), extensions now undeferred (`v5-extensions.md`), then one consistency pass and
      the `v5-changes.md` section.
  11. Critic on draft 3.6, then the architect applies it.
  - R40 Studio trap line → the integrity architect unit.
  - Codecs-in-scripts found a reachability gap in `v5-integrity.md` §3 (namespace iteration) → the integrity architect unit.
- Author direction: codecs spread into game scripts can work. Reconsider it as a design
  problem, not a refusal: look for a form that serves two purposes at once (e.g. per-site code that is both faster
  and harder to isolate), transforming the built output rather than the developer's source if that removes the
  script-rewrite problems. If no such form holds up, say why plainly; that outcome is acceptable.
