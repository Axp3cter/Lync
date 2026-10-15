---
family: declaration
since: 5.0.0
---

# intBounds

`t.int(min, max)` takes integers with -2^52 <= min <= max <= 2^52 - 1 (v5.md §3.3). Both bounds are
given, or neither, for `t.int()`.

## Example

The module `ReplicatedStorage.Net.schema`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local t = Lync.types

local health = t.int(100, 0)
```

raises:

```example
ReplicatedStorage.Net.schema:5: [Lync] intBounds: t.int max must be an integer from min to 2^52 - 1, got 0
```

## Fix

Give the bounds in order, as integers within the range. For any integer, use `t.int()`.
