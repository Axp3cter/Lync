# field-typing: runtime-path `field(path)` typing at 10+ paths

Question: can the runtime (no-build) path type `Net.<def>:field(path)` exactly for definitions with 10 or more
field paths (`reviews/v5-3.6-core-api.md` D1, `probes/review-3.6-core-api/nested_typefn.luau`)?

Tools: luau-analyze 0.740 (the luau skill's pinned toolchain, `~/.cache/luau-skill`), `--solver=old|new`;
tsc 6.0.2 `--strict`. Luau source read: `.data/projects/luau`. Re-run: `run.sh LUAU_ANALYZE` > `run.out`.

## Checklist

- [ ] 1. The limit is a fixed count of overloads or of type-function reductions; name the constant and file that sets it.
- [ ] 2. A runtime-path form gives exact handle types at 10, 32, 128 paths on the new solver (forms a–e; correct
      call typed, wrong path and wrong option rejected).
- [ ] 3. The same form type-checks on the old solver (or its fallback type is stated exactly).
- [ ] 4. roblox-ts: the `.d.ts` equivalent of the chosen form under `tsc --strict`, 10/32/128 paths.
- [ ] 5. Type-check time of the chosen form at 128 paths on both solvers.

## Results
