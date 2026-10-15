# Codecs in game scripts: weaving per-site encoders into built output

Researcher findings, 2026-10-15. **Decision it feeds:** whether v5 should emit each call site's encode (and,
server-side, decode delivery) into the game scripts that use it, which draft 3.5 refused (`v5-changes.md`, "Codecs
scattered into game scripts"), and in which form. The refusal is not inherited: each of its reasons is re-tested.

**Labels.** **verified**: I ran it or read the source. **documented**: official docs say so. **reported**: a third
party says so. **unverified**: inference or nothing found.

**Tools.** Luau 0.742 built from `.data/projects/luau` (CMake Release, scratch build, not committed); the luau skill's
`luau-ast`/`luau-compile` 0.740 and API dump 0.741.19; Rojo 7.7.1 and Lune 0.11.0 release binaries. Machine: Xeon
2.1 GHz, 4 cores, shared with other researchers, timings pinned to an idle core (`taskset -c 3`); CLI timings show
scale only, and phones are slower by an unmeasured factor.

**Probes** (`.data/docs/probes/codecs-in-scripts/`):
- `gen.py`: runtime model, client shard model and game-script models in every call-site form (shard and woven);
  `host.cpp`: a harness linked to the 0.742 VM that runs several chunks in one sandboxed VM, each interpreted,
  native, or as on a Roblox server (only `--!native` modules and `@native` functions); `bench.sh`, `summarize.py`,
  output `bench.out`, `bench.md`.
- `size.py`: bytecode of woven against shared forms (`size.out`); `size_orig.out`: the 5.0x probe re-run.
- `fixture/`, `place_io.luau` (Lune), `weave.py`: a prototype weaver over a `rojo build` place; `diff_mock.luau`,
  `diff_drive.luau`: original-against-woven differential.

Sibling briefs read and cited: `research/security-tooling.md` §10 (cited `[ST §n]`), `research/generation-security.md`
(`[GS §n]`), `research/client-security-build.md` (`[CSB §n]`), `research/client-security.md` (`[CS §n]`).

## Plan (ticked as written)

- [ ] 0. Bottom line
- [ ] 1. The refusal, re-tested
- [ ] 2. Where the transform runs
- [ ] 3. The typed API on both solvers and roblox-ts
- [ ] 4. Finding call sites and proving a definition closed
- [ ] 5. Line preservation and error positions (source maps)
- [ ] 6. Cost: bytecode, load, encode and decode time, build time
- [ ] 7. Dual-purpose form: site-bound wire ids
- [ ] 8. Interaction with seed, rotation, per-player variants, tag, schema hash
- [ ] 9. Options
- [ ] Implications
