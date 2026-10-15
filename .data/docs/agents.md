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
| `adb93333f6c4648cf` | scout | all of `.data/docs` in full; every refused, dropped or undecided security measure, its reasons, what they assume, and whether each cited cost or limit was measured, derived or asserted | `research/security-refusals.md` | running |
| `ae7b1fdfd83468cdb` | researcher | generation facts: obfuscation rules by channel, per-player code delivery, what a client reads from a shard, generated code vs Luau limits and native codegen, load cost, prior art | `research/generation-security.md`, `probes/generation-security/` | running |
| `ade0c89512482ae96` | researcher | API catalogue for security: Roblox engine (server, client), Studio plugin, Open Cloud, Lute, Lune, mlua, darklua, luau-lsp, rojo, Python, the executor API | `research/security-tooling.md`, `probes/security-tooling/` | running |

Paths are relative to `.data/docs/`, except builders' paths, which are relative to the repo root.

## Next

- Built code removed at the author's request (in git at `f1fbfd7`, not on this remote; evidence data in
  `probes/build/`). Design at draft 3.5. No milestone work without the author's go-ahead.
- Security re-judgment in progress: the three agents above, then an architect writes draft 3.6, then a critic
  reviews it.
- Author direction for the architect: codecs spread into game scripts can work. Reconsider it as a design
  problem, not a refusal: look for a form that serves two purposes at once (e.g. per-site code that is both faster
  and harder to isolate), transforming the built output rather than the developer's source if that removes the
  script-rewrite problems. If no such form holds up, say why plainly; that outcome is acceptable.
