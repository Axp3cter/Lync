---
family: declaration
since: 5.0.0
---

# newestPlacement

`:newest()` marks a collection field that is sent unreliably and repaired (v5-collections.md). It is
allowed only on a collection's top-level `data` fields, not in events or requests, nested records,
keys, or inside other codecs (v5.md §3.3).

## Example

The module `ReplicatedStorage.Net.schema`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local t = Lync.types

return Lync.schema("arena", {
	strike = Lync.event({
		from = "client",
		data = { aim = t.direction(11):newest() },
	}),
})
```

raises:

```example
ReplicatedStorage.Net.schema:8: [Lync] newestPlacement: arena.strike data.aim must be a top-level data field of a collection to use :newest()
```

## Fix

Remove `:newest()`, or move the field to a collection's top-level data.
