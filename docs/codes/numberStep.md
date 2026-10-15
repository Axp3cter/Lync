---
family: declaration
since: 5.0.0
---

# numberStep

`t.number(min, max, step)` and `t.vector3(min, max, step)` need (max - min) / step to be within 1e-9
× max(1, r) of a whole number of steps, which fixes the codec's width (v5.md §3.3). `t.number(0, 1,
0.35)` is refused; `t.number(0, 0.3, 0.1)` has 3 steps.

## Example

```luau
charge = t.number(0, 1, 0.35),
```

```example
ReplicatedStorage.Net.schema:14: [Lync] numberStep: t.number step must divide max - min into a whole number of steps, got 0.34999999999999998
```

## Fix

Choose a step that divides the range, or widen the range to a multiple of the step.
