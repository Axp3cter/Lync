---
family: declaration
since: 5.0.0
---

# mapKey

A map's keys, and a collection's `key`, are integers (`t.int`), list enums (`t.enum({ ... })`,
compared by index) or strings (`t.string`, compared bytewise), since keys are sent in ascending
order (v5.md §3.3, §3.4).

## Example

```luau
flags = t.map(t.bool(), t.int(0, 10), 8),
```

```example
ReplicatedStorage.Net.schema:16: [Lync] mapKey: t.map key must be a t.int, list t.enum or t.string codec, got "bool"
```

## Fix

Key the map by an integer, a list enum or a string.
