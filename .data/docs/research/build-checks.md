# Build checks: foreign remotes, dynamic access, shard drift and a code hash in `HELLO` (U5, U6)

Researcher findings, 2026-10-15. **Decision it feeds:** whether and how v5 adopts items U5 and U6 of
`research/security-refusals.md` §4, which the research described (`research/client-security-build.md` §4.1–§4.3,
cited CSB) but the design never decided. The exact rule, where it runs, output, false positives and cost of each.

**Labels.** **verified**: I ran it or read the source. **documented**: official docs or the design say so.
**reported**: a third party says so. **unverified**: inference, or nothing found.

**Tools.** Lune 0.11.0 and Rojo 7.7.1 (official Linux release binaries, in scratch, not committed); Luau 0.742
built from `.data/projects/luau` (CMake Release, scratch build); the luau skill's API dump 0.741.19; creator-docs
at the commit cached by `security-tooling.md` (cited by file). Machine: Xeon 2.1 GHz, 4 cores, shared, timings
pinned to one core (`taskset -c 3`). CLI timings show scale only.

**Probes** (`.data/docs/probes/build-checks/`, all reproduced by `run.sh`):
- `lex.luau`: a token-level Luau lexer of the kind the core carries (CSB §1.1);
- `scan.luau`: the shared scan: namespace bindings, `dynamicAccess` (3 kinds), and remote creation sites;
- `fixture_place.luau` → `check.luau` → `check_fixture.out`: a 41-instance place with every case marked EXPECT or
  CLEAN in its source;
- `scale_place.luau` → `scale.out`: places of 10k, 100k and 500k instances, sources cycled from 217 real Luau files;
- `bench_scan.luau`, `corpus_module.py` → `bench_scan.out`: lex and scan throughput under Luau 0.742;
- `rojo-fixture/`, `make_rbxm.luau` → `rojo_sourcemap.out`: what `rojo sourcemap` and `rojo build` expose;
- `scan_files.luau` → `real_creation.out`: the creation-site scan over Knit's Comm and Cmdr (fetched to scratch);
- `drift.luau` → `drift.out`: the shard self-digest, the drift cases it separates, SHA-256 cost.

## Checklist

- [ ] 0. Bottom line
- [ ] 1. U5a `foreignRemotes`
- [ ] 2. U5b `dynamicAccess`, and how it and the reachability rule agree
- [ ] 3. U6a Shard drift: what is hashed, the checks, where they run
- [ ] 4. U6b A code hash in `HELLO`
- [ ] Implications
