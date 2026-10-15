---
family: declaration
since: 5.0.0
---

# unionKindField

A `t.union` value carries its variant's name in `kind`, so a variant record cannot have a field of
its own named `kind` (v5.md §3.3).

## Example

```luau
data = t.union({ round = { kind = t.int(1, 3) } }),
```

```example
ReplicatedStorage.Net.schema:13: [Lync] unionKindField: arena.announce data.round must not have a field named kind, the union's discriminant; rename the field
```

## Fix

Rename the field.
