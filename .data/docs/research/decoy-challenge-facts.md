# Decoy-adjacent facts (U11) and server-issued challenges (U14)

Researcher findings, 2026-10-15. **Decision it feeds:** what the architect writes into `v5-integrity.md` for the two
items `research/security-refusals.md` §4 lists as described but never decided: U11 (a rewound hit on a decoy, a
game-reported interaction with a decoy, a build lint for client-sent key fields into decoy collections) and U14
(server-issued challenges). Lync reports facts with exact triggers and numeric evidence; it never judges, scores or
acts beyond dropping malformed input.

Read in full: `design/v5.md` §3.4–§3.6, §5.2, §6, §7; `design/v5-integrity.md`; `design/v5-collections.md`;
`research/anticheat-design.md` (AC) §2, §4.1, §4.3, §7, §8; `research/generation-methods.md` §0 and M15;
`research/interest-rewind.md` (IR) §1–§3, §6, §8, §10, §11; `research/diagnostics.md` §2, §5;
`research/client-security.md` (CS) §1; `research/checks-telemetry.md` C5 (lint conventions).

**Labels.** **verified**: I ran it or read the source. **documented**: official docs say so. **reported**: a third
party says so. **unverified**: inference, or nothing found.

**Capability classes** as `generation-methods.md` §0 groups CS §1.2: **code**, **mem**, **api**, **hook**,
**signal**, **packet**, **identity**, **naming**, **clock**, **state**, **share**.

**Tools.** Luau 0.742 built from `.data/projects/luau` (Release; `luau -O2` interpreted stands for clients,
`--codegen` native for servers); `luau-analyze` 0.740 (the `luau` skill's pinned toolchain) with `--solver=new` and
`--solver=old` for typing probes; the skill's Roblox API dump 0.741.19 for member lookups. CLI on a shared 2.1 GHz
Xeon: timings show scale only.

**Probes** (`.data/docs/probes/decoy-challenge-facts/`): listed in §9.

## Checklist

- [ ] 0. What exists today, and the gaps U11 and U14 fill
- [ ] 1. U11a: decoys under `rewind` (rings, `held`, what `rewound` returns)
- [ ] 2. U11b: `reportInteraction` and the fact `decoyInteraction`
- [ ] 3. U11c: the build lint `decoyRef`
- [ ] 4. U11: what it protects, how it fails on an unmodified client, cost, options
- [ ] 5. U14: mechanism, what Lync carries and what the game designs, API (Luau and roblox-ts)
- [ ] 6. U14: outcome, facts and evidence
- [ ] 7. U14: known causes on an unmodified client, accessibility included
- [ ] 8. U14: what it protects, cost, options
- [ ] 9. Probes and measurements
- [ ] Implications
