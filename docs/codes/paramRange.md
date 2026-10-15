---
family: declaration
since: 5.0.0
---

# paramRange

A constructor parameter or a definition option is outside its declared type or range: a length or
count outside 1 to 65,535, `t.direction` bits outside 8 to 16, `t.rotation` bits outside 7 to 15, a
non-finite number, a step that is not above 0, `from` or `lane` outside their values, a `timeout`
outside 0.1 to 300 s, `maxRecords` outside 1 to 65,536, or a `limit.burst` outside 1 to 1000. The
ranges are in v5.md §3.3 and §3.4.

## Example

The module `ReplicatedStorage.Net.schema`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local t = Lync.types

local name = t.string(0)
```

raises:

```example
ReplicatedStorage.Net.schema:5: [Lync] paramRange: t.string maxBytes must be an integer from 1 to 65535, got 0
```

## Fix

Give a value inside the range the message states.
