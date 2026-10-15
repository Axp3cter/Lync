---
family: declaration
since: 5.0.0
---

# unionKindField

A `t.union` value carries its variant's name in `kind`, so a variant record cannot have a field of
its own named `kind` (v5.md §3.3).

## Example

The module `ReplicatedStorage.Net.schema`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local t = Lync.types

return Lync.schema("arena", {
	announce = Lync.event({
		from = "server",
		data = t.union({ round = { kind = t.int(1, 3) } }),
	}),
})
```

raises:

```example
ReplicatedStorage.Net.schema:8: [Lync] unionKindField: arena.announce data.round must not have a field named kind, the union's discriminant; rename the field
```

## Fix

Rename the field.
