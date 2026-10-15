# Inbound bound, re-measured on every shape it must cover

2026-10-15. Prover unit. Re-measures the inputs of `design/v5.md` §7.5's inbound CPU bound (draft 3.6:
c_f·frames + c_b·bytes + p(L)·elements, p(L) = 2,000 + 133·L ns) after `reviews/v5-3.6-runtime.md` findings 2–7,
on the milestone build's receive path (`f1fbfd7:src`, exported outside the repo by `run.sh`) and on a generated
decoder (`gen.luau` → `gen_decoders.luau`, written into the work directory). Inputs read:
`probes/inbound-budgets/` (RESULTS.md and probes), `probes/review-3.6-runtime/` (`probe.luau`, `probe2.luau`,
`shape.luau`, `acc.py`).

## Checklist

Stated in the terms of the restructured §7.5 (decode units; coordinator, mid-task): each element costs
w = ⌈p(L) / 100 ns⌉ units, p(L) = p_0 + p_1 × L over that element's own leaves (arrays and maps 2, a union's tag 1,
an optional's presence 1, `t.vector3`/`t.color3`/`t.vector3f32` 3, `t.direction` 2, `t.rotation` 4, `t.cframe` 7),
and one frame costs at most (1 + μ) × (c_f + c_b × its charge + 100 ns × its units).

- [ ] 1. A per-leaf cost model over every codec shape (scalars, strings, buffers, arrays, maps, optionals, unions,
      records, nested), stated as p(shape) with its fit and maximum residual over every measured case; whether
      100 ns per unit, at p_0 = 2,000 ns and p_1 = 133 ns with the weights above, is an upper bound over every shape,
      and the worst residual (milestone and generated decoders, native and interpreted)
- [ ] 2. c_f and c_b per lane with every candidate hashed and every accepted position (reliable e … e + 4,
      unreliable each of the 3 extensions), plus the instance-list walk per entry (now in step 2) and the untagged
      `HELLO` path (now never hashed, decoded under the unit charge)
- [ ] 3. The bound with these inputs, its worst case at the current defaults, and the defaults that meet 2 ms/s
      per player native at μ = 0, 0.10 and 0.25 (one marked chosen)
- [ ] 4. The §9 CI gate: a test that fails when any shape exceeds the bound, with the shapes it must include
      (shown failing on draft 3.6's per-element bound and passing on the new one)

## Results

(appended as each probe runs)
