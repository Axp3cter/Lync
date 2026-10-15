---
family: declaration
since: 5.0.0
---

# unreliableTooLarge

An unreliable event's worst-case encoded size is over 960 bytes, or a collection's `:newest()` row
is, so it could not always fit an unreliable frame (v5.md §3.4, §4.9).

## Example

The module `ReplicatedStorage.Net.schema`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local t = Lync.types

return Lync.schema("arena", {
	shout = Lync.event({ from = "client", lane = "unreliable", data = t.string(1000) }),
})
```

raises:

```example
ReplicatedStorage.Net.schema:6: [Lync] unreliableTooLarge: arena.shout data must encode in at most 960 bytes, got 1002
```

## Fix

Lower the maximum lengths or counts, or send it on the reliable lane.
