# Evidence from the milestone build

The milestone 1 and 2 code was built, measured and then removed at the author's request. The full code, its tests
and the scripts that produced these files are in git at commit `f1fbfd7` (`src/`, `test/`, `bench/`, `docs/codes/`).
This folder keeps only the data the design and research cite:

- `golden/`: the golden frames G2–G11 and the permutation vector, as `.bin` files with their `index.json`
  (built and decoded by the milestone code; the hex is also in `v5.md` §4.10).
- `results/`: benchmark output as JSON lines.
  - `579015b.json`, `c91960e.json`: column coder encode with the full k search and k = 0, decode, EG-0 decode
    (per value and batched) and HalfSipHash, interpreted and native (`bench/column.bench.luau` at those commits).
  - `rotation-3a222e0.json`: `t.rotation` decode with and without the canonical check, interpreted and native
    (`test/codec/rotation.bench.luau`).

Scripts cited by the design at that commit: `test/wire/quant.spec.luau` (direction and rotation worst-case search),
`test/codec/rotation_full.luau` (exhaustive and random canonical rotation runs, error search),
`test/codec/min_rows.luau` (`columnMinRows`).

**Superseded by draft 3.5:** the upstream tag is now 32 bits, so `golden/G4.bin`, `G5.bin` and `G8.bin` here are the
16-bit forms the build produced. The current hex is in `v5.md` §4.10, built by `probes/design-3.5/golden_tag32.luau`.
