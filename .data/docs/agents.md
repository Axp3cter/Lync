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
| `ad69e26579bcfc07b` | prover | re-measures every performance figure used to refuse or narrow a security measure, plus generated cheaper forms | `probes/security-costs/RESULTS.md` | done: 2–3x shuffle false (≤ 14% generated); masking bytes false for v5 (0% bit section); downstream tag true native ≤ 1 KB, false interpreted; id shuffle negligible; `tag.cover` bound false (fixed per-frame cost, over-budget frames still hashed); rotation ≤ 2 bits false; `getfenv` 4.9x/52x; R39 hook free; retired |
| `a5072800c2daf5fdc` | researcher | **the methods agent**: concrete generation methods in Lync's pipeline; re-checks M1–M12 against their probes and goes further (per-player tag binding, generated traps/decoys/canaries, runtime-path per-session parameters) | `research/generation-methods.md`, `probes/generation-methods/` | M1–M12 done, all on Opus 5.5; key finding: the build seed is public, so per-build values price nothing until a private `rotationSeed` exists (M1); per-session/per-player layouts vary upstream only; retired |
| `a6b292c4df871349d` | researcher | client shard self-checks: finishes `security-tooling.md` §2; U1 captured `FireServer`, U2 tag rounds and rotation amounts, U7 caller information in the tag | `research/security-tooling.md` §2, `research/client-self-checks.md`, `probes/client-self-checks/` | done on Opus 5.5, nothing unwritten; U1 captured method (≤ 8 ns less, `__namecall` spies only), U2 rounds (vetted rotation pool, `build.tagRounds`), U7 one caller bit in the lane byte, replacing `sourceUnlisted`; retired |
| `a0f684951116653fa` | researcher | unit 2: `rewind` (D2), U15 streaming guidance, the PlayerGui variant timing rule | `research/interest-rewind.md` §11–§13, `probes/interest-rewind/` | done on Opus 5.5, nothing unwritten; rewind 24 B per record per tick, perceived tick from acks plus ping, server-chosen interpolation delay in `RATE`; staged release via `Lync.release`; variant timing rule; retired |
| `aaaa767102bda45cc` | researcher | unit 3: `checks` (D3) and the free-form field lint (U12) | `research/checks-telemetry.md` C0–C7, `probes/checks-telemetry/` | done on Opus 5.5: `within`, `monotonic` (frame-keyed order), `maxTotal` (16-bucket window), `:claim()`/`:input()`, `freeFormField` lint, one `constraint` fact; retired |
| `a052ba82d8257f6be` | researcher (Opus) | unit 6a: M13 per-player tag or key binding, M14 runtime path with per-session parameters | `research/generation-methods.md` M13–M14, `probes/generation-methods/run3.sh` | done on Opus 5.5: M13 per-player tag mask and `tagVariant` fact, `Lync.variantOf`; M14 runtime path tables (closure tree 1.45–1.72x generated), `layout.vary`; retired |
| `a90ea3732751c0bdf` | researcher (Opus) | unit 6b: M15 generated traps, decoys and canaries; M16 composition with codecs in game scripts | `research/generation-methods.md` M15–M16, `probes/generation-methods/run4.sh` | done on Opus 5.5: `build.traps` 0–8 (reopens R13), `decoyFrom`, `canary.perViewer`; weaving composition table and `weaveHash` coverage; retired |
| `aeb8a1de57c0b9d73` | researcher (Opus) | unit 5: U5 `foreignRemotes` and `dynamicAccess` (agreeing with the reachability gap), U6 core hash in `HELLO` and manifest drift | `research/build-checks.md`, `probes/build-checks/` | done on Opus 5.5: `foreignRemotes` inventory, `dynamicAccess` = incompleteness (fixes the reachability gap), `editedShard`/`unpairedShard`/`staleManifest`; code hash in `HELLO` not recommended for protocol v1; retired |
| `a37cd6952a2f7bad9` | researcher (Opus) | unit 7: U9 `Lync.derive`, U10 reaction floor on `:reactsTo` | `research/server-facts.md`, `probes/server-facts/` | done on Opus 5.5: `derive` as a fourth check kind (grid-rounded tolerance; native FMA differs from interpreted), `reactsTo` with `earlyReaction` and a proposed 1 B `rcv` receipt on reliable upstream frames; its checklist's U11/U14/U3/U4 rows are covered by `decoy-challenge-facts.md` and `clock-facts.md`; retired |
| `a3a196cb42882d70c` | researcher (Opus) | unit 8: U11 decoy-adjacent facts, U14 server-issued challenges | `research/decoy-challenge-facts.md`, `probes/decoy-challenge-facts/` | stopped by the author; partial files committed; not resumed |
| `a8535342774a83e31` | researcher (Opus) | unit 4: `telemetry` (D4), Roblox terms on off-platform data | `research/checks-telemetry.md` T1–T5, `probes/checks-telemetry/` | done on Opus 5.5: `:aim`/`:series`/`:atom` on the server view, pushed atom batches and pulled streams, no facts or export; Roblox terms quoted (Creator Terms change 2026-11-01); found a §5.1 flush-rule ambiguity (40 vs 60 Hz); retired |
| `a10703eb41a07ff5b` | researcher (Opus) | unit 6c: consolidates `generation-methods.md` (M7 vs M13, Summary M1–M16, one Implications list, checklist); no new methods or numbers | `research/generation-methods.md` | done on Opus 5.5: 15 edits, no number changed; M1–M16 consistent, one Summary and one Implications list; retired |
| `a476c0bb5505e0898` | researcher (Opus) | unit 9: U3 beacon window rules, U4 `roundTrip`/`ping` on request results | `research/clock-facts.md`, `probes/clock-facts/` | stopped by the author; partial files committed; not resumed |
| `aa6e643bca7187c05` | scout (Opus) | change list for draft 3.6: every proposal by target file and section, conflicts, cross-unit questions, R items with no proposal, pending measurements; placeholders for the four briefs still running | `design/v5-3.6-inputs.md` | stopped by the author; partial files committed; not resumed |
| `a5ef019e234ca4f1b` | researcher (Opus) | re-judges R10 darklua renaming, R11 manifest self-attestation, R31 per-frame decode budget, R33 upstream interning, R34 commit–reveal | `research/refusals-rejudged-1.md`, `probes/refusals-rejudged/` | done on Opus 5.5: R10 kept refused, R11 narrowed (`lync check --published` via Open Cloud), R31 kept refused (found byte budgets bound decode CPU at 13.1–17.7 ms/s per player interp, defaults unmeasured), R33 narrowed (refs to server-sent tables), R34 narrowed (sealed delivery; placed in milestone 7, a deferral the architect resolves); retired |
| `a928f08cbc1635fcd` | researcher (Opus) | re-judges R26 `REPORT` forcing a frame, R27 `REKEY` rate, R32 client element bucket, R37 per-fit clock counter, R38 calls-per-second signal | `research/refusals-rejudged-2.md`, `probes/refusals-rejudged/r2_*` | done on Opus 5.5: R26 adopt (pending reliable data on non-zero counts), R27 narrowed (one pending `REKEY` per player; found the `REKEY-ACK` raise gap), R32 kept refused on correctness (server `elementsSent`; §4.8 hang claim to correct), R37 adopt as counters, R38 narrowed to per-lane counters; retired |
| `a5b3bafd396671a88` | researcher (Opus) | clock unit restarted: U3 beacon window rules, the `BEACON` frame gap, U4 `roundTrip`/`ping`; builds on R37's counters and U10's path estimate | `research/clock-facts.md`, `probes/clock-facts/` | done on Opus 5.5: no server-wide clock rule (evidence `othersSlope`/`others` instead); split-half test against delay steps; `BEACON` as pending reliable data; `roundTrip`, `pingAtSend`, `pingAtAnswer`, `minPing` on results; retired |
| `a4b3fa7fe7846b2d5` | scout (Opus) | change list restarted: by target, conflicts, simplifications, cross-unit questions, R items with no proposal, pending measurements | `design/v5-3.6-inputs.md` | done on Opus 5.5 (clock folded in: +15 changes, +3 conflicts, +5 simplifications; §9–§10 placeholders for rejudged-3 and -4): 216 changes (v5 96, integrity 60, collections 10, tooling 25, extensions→core 7, change records 18), 26 conflicts, 41 simplifications, 14 R items with no verdict; clock placeholder §8 open; reuse to fill it |
| `a0d8f5898e745dd3f` | prover (Opus) | inbound byte budgets: decode + tag CPU per byte, budget → worst-case CPU formula, budget values at 1/5/10% of a core at 100 players | `probes/inbound-budgets/RESULTS.md` | done on Opus 5.5: worst case at defaults 242% of a core at 100 players native (busy-like schema; up to 1,552% with 128-field bool records); refused reliable frames still tag-checked (328 ms/s per player); bad-tag + unacked rekey doubles hash work; busy model alone 3.2% native; LP shadow-price formula; retired |
| `a51bbc2f379f51342` | researcher (Opus) | re-judges R1 downstream tags, R2 masking, R21 `limit` by send time, R28 64-bit tag, R39 frame hook | none kept | **fell back to another model** before its only write (whole file in one write); output moved to the lead's scratchpad as a checklist; do not reuse |
| `aa79aa80d88fe9844` | researcher (Opus) | re-judges R8 per-client code, R16 per-viewer decoy slots, R18 hook and environment checks, R19 client-side decoy filtering, R35 check modifiers | `research/refusals-rejudged-4.md`, `probes/refusals-rejudged/r4_*` | running |
| `a798ceabd47f0b432` | architect (Opus) | draft 3.6, area 1: `v5-tooling.md` from inputs §1.4 plus tooling conflicts, simplifications, questions | `design/v5-tooling.md`, `design/v5-3.6-changes-tooling.md` | done on Opus 5.5: 52 items (26 accepted, 21 changed, 5 rejected); one build-code table, severity rule, §5 Weaving, `idTableHash`, trap-name rule; Needs elsewhere for core-api, wire, runtime, integrity, collections; reuse to apply its critic review |
| `a20f7e408eee43070` | researcher (Opus) | redo of R1, R2, R21, R28, R39 after the fallback; cites probe outputs only | `research/refusals-rejudged-3.md` | running |
| `a7fcae0d7495104ff` | architect (Opus) | draft 3.6, core-api: `v5.md` §0–§3 and §5.2 | `design/v5.md`, `design/v5-3.6-changes-core-api.md` | running |
| `a2d5cd5acf9eac594` | architect (Opus) | draft 3.6, wire: `v5.md` §4; awaits rejudged-3 | `design/v5.md` §4, `design/v5-3.6-changes-wire.md` | running |
| `ae249a0e239ab2ca1` | architect (Opus) | draft 3.6, runtime: `v5.md` §5 (not §5.2), §6–§10; awaits inbound budgets, rejudged-3 R21 | `design/v5.md`, `design/v5-3.6-changes-runtime.md` | running |
| `aeb3f14bb82fa9e3c` | architect (Opus) | draft 3.6, integrity: `v5-integrity.md`; awaits rejudged-3 (R1, R2, R28), rejudged-4 (R8, R18) | `design/v5-integrity.md`, `design/v5-3.6-changes-integrity.md` | running |
| `a75374bcd3227e4ff` | architect (Opus) | draft 3.6, collections: `v5-collections.md` plus interest, rewind, interpolation; awaits rejudged-4 (R16, R19) | `design/v5-collections.md`, `design/v5-3.6-changes-collections.md` | running |
| `a61dd67964f674f75` | architect (Opus) | draft 3.6, checks: new `v5-checks.md` (checks, derive, telemetry, sealed) and `v5-extensions.md`; awaits rejudged-4 (R35) | `design/v5-checks.md`, `design/v5-extensions.md`, `design/v5-3.6-changes-checks.md` | running |
| `a8d8d1902366d183b` | critic (Opus) | reviews `v5-tooling.md` at draft 3.6 against the shared brief | `reviews/v5-3.6-tooling.md` | running |

Paths are relative to `.data/docs/`, except builders' paths, which are relative to the repo root.

## Next

- Built code removed at the author's request (in git at `f1fbfd7`, present in this clone; evidence data in
  `probes/build/`). Design at draft 3.5. No milestone work without the author's go-ahead.
- Security re-judgment in progress: the agents above find facts and designs; then an architect brings them
  together into draft 3.6; then a critic reviews it. Designing new mechanisms is research work, not the architect's.
- Author direction: nothing is deferred. Items the docs push to milestone 7 or leave undecided get designed now.
  No new agents beyond the five above; follow-ups go to an agent once it finishes its current task.
- No simplifications, in wording or mechanism (author): Lync never acts on input beyond dropping malformed input
  and reporting facts (no clamping, rewriting, throttling or catch-all policies, so checks C0's `policy = clamp`
  goes); no presets, tiers, merged modes or one knob covering several triggers; every default derived or marked
  chosen; no vague quantities or judging words. Applies to every brief and to the architect pass.
- Process rule: every agent writes a header and a checklist first, then one section per edit, ticking it; an
  interrupted section is marked "not written" and the agent continues. Briefs are worded around what Lync builds.
- Generation-methods units (the methods agent and unit 6) must come from Opus 5.5 only: launched with the Opus
  model, transcript checked on return, and any section written on another model redone as its own unit.
- Units, smallest first, each to a fresh agent as a slot frees (at most ten Opus agents running, from the author). Fallbacks count as
  interruptions: a unit written after one is redone as its own unit.
  1. ~~`interest`~~ done.
  2. ~~`rewind`~~ done.
  3. ~~`checks`~~ done.
  4. ~~`telemetry`~~ done. D4, with Roblox's terms on off-platform data → append to `research/checks-telemetry.md`.
     Note for units 3–4: `probes/checks-telemetry/checks_cost.luau` exists; its "atom copy" line divides by N but runs N/10 copies (real figure 10x the printed one).
  5. ~~`build checks`~~ done.
  6a. ~~`methods, part 2a`~~ done.
  6c. ~~`methods, consolidation`~~ done.
  6b. ~~`methods, part 2b`~~ done.
  7. ~~`server facts A`~~ done.
  8. `server facts B`: U11, U14 → `research/decoy-challenge-facts.md` (on `a3a196cb42882d70c`).
  9. ~~`clock and timing`~~ done.
  9a. Re-judge the ten R items no brief covered: R10, R11, R31, R33, R34 → `refusals-rejudged-1.md`; R26, R27, R32, R37, R38 → `refusals-rejudged-2.md`.
  9b. Scout: `design/v5-3.6-inputs.md`, the change list the architect units read (on `aa6e643bca7187c05`).
  10. Architects, seven units by ownership (`design/v5-3.6-architect-brief.md`): tooling, core-api, wire, runtime,
      integrity, collections, checks; pending research goes to the owning unit by message. Then one consistency
      unit applies every "Needs elsewhere" list and merges the change records into `v5-changes.md`.
  11. Critic per area as each architect unit finishes (`reviews/v5-3.6-<unit>.md`); the same architect applies it. Then one critic over the merged draft.
  - R40 Studio trap line → the integrity architect unit.
  - R22 quiet mitigation hooks, R23 suspicion scores, R24 automatic consequences: kept refused by principle (facts, not verdicts; `v5.md` §1); the integrity architect records them.
  - `v5.md` §5.1 flush rule: "1/60 s since the last flush" gives 40 Hz from a steady 60 FPS client; an accumulator keeping the remainder gives 60 Hz (telemetry T5 item 10) → the wire architect unit.
  - Checks C0 proposes `policy = clamp`, which rewrites a client value instead of dropping it; weigh against "Lync only drops bad input" (§1) in the architect pass.
  - Self-checks open questions (direct method-call path for Instances, command-bar identity, renamed-script source, `task.spawn`) → add to `v5.md` §10 pending measurements in the architect pass.
  - Codecs-in-scripts found a reachability gap in `v5-integrity.md` §3 (namespace iteration) → the integrity architect unit.
- Author direction: codecs spread into game scripts can work. Reconsider it as a design
  problem, not a refusal: look for a form that serves two purposes at once (e.g. per-site code that is both faster
  and harder to isolate), transforming the built output rather than the developer's source if that removes the
  script-rewrite problems. If no such form holds up, say why plainly; that outcome is acceptable.
