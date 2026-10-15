---
family: declaration
since: 5.0.0
---

# numberStepIsInt

`t.number(min, max, 1)` with an integer `min` holds only integers, which `t.int(min, max)` codes
exactly and without quantization (v5.md §3.3).

## Example

```luau
score = t.number(0, 100, 1),
```

```example
ReplicatedStorage.Net.schema:14: [Lync] numberStepIsInt: t.number step must not be 1 with an integer min, got 1; use t.int(min, max)
```

## Fix

Use `t.int(min, max)`.
