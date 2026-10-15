---
family: declaration
since: 5.0.0
---

# optionalPlacement

A `t.optional` directly inside another `t.optional`, as an array element or as a map value (v5.md
§3.3). Each would give one value a second encoding, or, for a map, a pair a Luau table cannot hold.
An optional inside a record is allowed, in any of these places.

## Example

The module `ReplicatedStorage.Net.schema`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local t = Lync.types

local titles = t.array(t.optional(t.string(16)), 8)
```

raises:

```example
PENDING
```

## Fix

Remove the inner `t.optional`, or wrap it in a record field.
