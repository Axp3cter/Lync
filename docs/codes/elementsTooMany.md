---
family: declaration
since: 5.0.0
---

# elementsTooMany

A message's worst-case element count W is over 65,536 (v5.md §3.4, §4.8). W is 1 for the message,
plus each array element and map pair with what it holds, at the declared maximum counts; an
optional, a convert and the largest union variant count as what they hold.

## Example

The module `ReplicatedStorage.Net.schema`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local t = Lync.types

return Lync.schema("arena", {
	grid = Lync.event({ from = "server", data = t.array(t.array(t.bool(), 64), 2048) }),
})
```

raises:

```example
PENDING
```

## Fix

Lower the maximum counts, or split the data across messages.
