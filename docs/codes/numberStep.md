---
family: declaration
since: 5.0.0
---

# numberStep

`t.number(min, max, step)` and `t.vector3(min, max, step)` need (max - min) / step to be within 1e-9
× max(1, r) of a whole number of steps, which fixes the codec's width (v5.md §3.3). `t.number(0, 1,
0.35)` is refused; `t.number(0, 0.3, 0.1)` has 3 steps.

## Example

The module `ReplicatedStorage.Net.schema`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local t = Lync.types

local charge = t.number(0, 1, 0.35)
```

raises:

```example
ReplicatedStorage.Net.schema:5: [Lync] numberStep: t.number step must divide max - min into a whole number of steps, got 0.35
```

## Fix

Choose a step that divides the range, or widen the range to a multiple of the step.
