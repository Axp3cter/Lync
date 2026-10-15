---
family: declaration
since: 5.0.0
---

# newestPlacement

`:newest()` marks a collection field that is sent unreliably and repaired (v5-collections.md). It is
allowed only on a collection's top-level `data` fields, not in events or requests, nested records,
keys, or inside other codecs (v5.md §3.3).

## Example

```luau
data = { aim = t.direction(11):newest() },
```

```example
ReplicatedStorage.Net.schema:10: [Lync] newestPlacement: arena.strike data.aim must be a top-level data field of a collection to use :newest()
```

## Fix

Remove `:newest()`, or move the field to a collection's top-level data.
