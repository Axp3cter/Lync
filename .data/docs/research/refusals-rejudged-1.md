# Refusals re-judged, part 1: R10, R11, R31, R33, R34

Researcher findings, 2026-10-15. **Decision it feeds:** whether each of five refused items (numbers from
`research/security-refusals.md` §2) stays refused, or enters the v5 design and in what form. The author's
direction: earlier refusals leaned on run-time limits and costs that were not worked through, and assumed that work
had to happen at run time or identically for every player. Generation (`research/generation-methods.md` §0, Summary)
is now available. Each item gives the earlier reason and its assumption, what it would protect (capability classes
of `client-security.md` §1.2, as grouped in `generation-methods.md`: **code**, **mem**, **api**, **hook**,
**signal**, **packet**, **identity**, **naming**, **clock**, **state**, **share**), a form in Lync's terms, its
measured cost, its facts, and a one-line outcome. Lync reports facts and drops only malformed input.

**Labels.** **verified**: I ran it or read the source. **documented**: official docs or the design say so.
**reported**: a third party says so. **unverified**: inference, or nothing found.

**Tools.** Luau 0.742 built from `.data/projects/luau` (Release, scratch build): `luau -O2` stands for clients
(interpreted), `luau -O2 --codegen` for servers (native; a Roblox server runs native code only for scripts marked
native, so interpreted figures also bound an unmarked server). Intel Xeon 2.1 GHz, 4 cores, shared machine; CLI
timings show scale only, devices are slower by an unmeasured factor. The milestone build's decoder (`f1fbfd7:src`)
is extracted to scratch by `run.sh` and never copied into the repo. API facts from the luau skill's dump 0.741.19.

**Probes** (`.data/docs/probes/refusals-rejudged/`, all by `sh run.sh BUILD_DIR WORK_DIR`, 3 runs per mode):
- `r10_base.luau`, `r10_names.sh` → `r10_names.out`: which renames change shipped bytecode, at `-g0`, `-g1`, `-g2`;
- `r31_decode.luau` → `r31_decode.out`: the milestone decoder's CPU and heap per element for the worst shapes the
  planner accepts, and for a dense record;
- `r33_intern.luau` → `r33_intern.out`: heap per intern entry; a reference against a literal at decode;
- `r34_seal.luau` → `r34_seal.out`: a HalfSipHash-2-4/64 counter-mode keystream, checked against the reference port
  in `probes/security-costs/hsip.luau`.

## Checklist

- [ ] R10. darklua renaming as polymorphism
- [ ] R11. Manifest self-attestation of client scripts
- [ ] R31. A per-frame decode budget proportional to frame bytes
- [ ] R33. Upstream (client-to-server) string interning
- [ ] R34. Commit–reveal or cryptographic state sharing as a general feature
- [ ] Implications

---
