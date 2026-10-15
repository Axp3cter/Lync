---
family: declaration
since: 5.0.0
---

# numberStepIsInt

`t.number(min, max, 1)` with an integer `min` holds only integers, which `t.int(min, max)` codes
exactly and without quantization (v5.md §3.3).

## Example

The module `ReplicatedStorage.Net.schema`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local t = Lync.types

local score = t.number(0, 100, 1)
```

raises:

```example
ReplicatedStorage.Net.schema:5: [Lync] numberStepIsInt: t.number step must not be 1 with an integer min, got 1; use t.int(min, max)
```

## Fix

Use `t.int(min, max)`.
