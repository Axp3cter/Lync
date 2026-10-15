---
family: declaration
since: 5.0.0
---

# zeroWidthElement

An array or map whose element costs 0 bits at its worst, such as `t.array({}, n)` or
`t.array(t.int(5, 5), n)`, carries nothing but its count, and a decoder would build its elements
from no bytes at all (v5.md §3.4, §4.8). A `t.int` carries the count alone.

## Example

The module `ReplicatedStorage.Net.schema`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local t = Lync.types

return Lync.schema("arena", {
	crowd = Lync.event({ from = "server", data = t.array({}, 100) }),
})
```

raises:

```example
ReplicatedStorage.Net.schema:6: [Lync] zeroWidthElement: arena.crowd data must have elements that cost at least 1 bit; send the count as a t.int
```

## Fix

Send the count as a `t.int`, or give the elements a field.
