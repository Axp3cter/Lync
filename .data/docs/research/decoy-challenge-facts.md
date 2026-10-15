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

- [x] 0. What exists today, and the gaps U11 and U14 fill
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

---

## 0. What exists today, and the gaps

**Decoys** (`v5-integrity.md` §8, verified by reading). `Net.c:decoys(behaviour, { maxPerViewer })` on the server
view; the behaviour returns per viewer `{ [Key]: Record }` each state tick; decoys take slots from a shared pool and
ride in per-viewer copies of changed chunks. M15b adds `Net.c:decoyFrom(sourceKey, overrides)` (values cloned from a
live record). IR §6.1 adds the rule that a decoy must pass the viewer's interest test (`decoyOutsideInterest`, a
caller error in the behaviour's thread).

**The one decoy fact today**, `decoyReferenced`: "a delivered message whose `refers` field holds a key of a decoy
sent to that player", evidence `sentAgo`, action delivered (`v5-integrity.md` §10). It needs
`Net.d:refers(field, collection)`; unknown fields throw `unknownField`.

**Rewind** (IR §11). `Net.c:perceived(player)` (only inside a handler's synchronous part), `Net.c:rewound(seen, key)`
→ `{ ok, value } | { ok = false, error = "expired" | "notHeld" | "unknownKey" }`, `rewoundSpan`, `at(tick, key)`.
IR §11.6 states the rule this unit keeps: **no `Lync.observe` fact from rewind, because Lync can't know a message is
a hit claim**; the game decides hits (R36 refuses a built-in verifier).

**Requests** (`v5.md` §5.2). A server `invoke(player, data)` already yields until the client's `handle` returns,
with `timeout` 0.1–300 s and the `earlyAnswer` fact. A client handler may yield (it runs in a pooled thread).

**Gaps.**
1. A rewound shot that names no target (origin and direction only) can land on a decoy only inside the game's own
   hit test, and that test never sees decoys: the game iterates its own records, and `rewound` holds no decoy
   rings. So "a rewound hit on a decoy" has no path at all today.
2. Interactions the server resolves from something other than a declared key field (a ray, "nearest pickup", a key
   nested in an array of records, a key sent on a non-Lync remote) are never matched against decoys.
3. Nothing tells the developer that a client-sent field could carry a decoy key without a `refers` declaration, so
   `decoyReferenced` silently never fires for it.
4. There is no server-issued challenge. A server request carries a UI answer, but its shape is the same in every
   Lync game: a dedicated ask, answered by the client's `handle`. Anything identical across Lync games gets one
   universal bypass, published once (CS §1.4, "Economics of a shared library").
