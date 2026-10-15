---
family: declaration
since: 5.0.0
---

# intBounds

`t.int(min, max)` takes integers with -2^52 <= min <= max <= 2^52 - 1 (v5.md §3.3). Both bounds are
given, or neither, for `t.int()`.

## Example

```luau
health = t.int(100, 0),
```

```example
ReplicatedStorage.Net.schema:29: [Lync] intBounds: t.int max must be an integer from min to 2^52 - 1, got 0
```

## Fix

Give the bounds in order, as integers within the range. For any integer, use `t.int()`.
