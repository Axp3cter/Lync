---
family: declaration
since: 5.0.0
---

# newestWidth

A `:newest()` field is sent in fixed-size rows, so its codec has no lengths, counts, Exp-Golomb
codes, instances or custom encodings: `t.string`, `t.buffer`, `t.array`, `t.map`, `t.int()`, Roblox
enums, `t.instance` and `t.custom` are refused, alone or inside another codec (v5.md §3.3).

## Example

The module `ReplicatedStorage.Net.schema`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local t = Lync.types

return Lync.schema("arena", {
	fighters = Lync.collection({
		data = { name = t.string(20):newest() },
	}),
})
```

raises:

```example
ReplicatedStorage.Net.schema:7: [Lync] newestWidth: arena.fighters data.name must have a fixed-width codec to use :newest(), got "string"
```

## Fix

Remove `:newest()` from the field, which is then sent reliably.
