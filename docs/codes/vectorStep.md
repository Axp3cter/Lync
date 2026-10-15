---
family: declaration
since: 5.0.0
---

# vectorStep

A `t.vector3`, or a `t.cframe` position, is stored in f32, so a component can sit up to one f32
spacing past a bound. Its `step` must be larger than the f32 spacing at max(|min|, |max|),
2^(floor(log2 M) - 23), so that every decoded component re-quantizes to its own code (v5.md §3.3).
With bounds of ±2048 the spacing is 2^-12, so `1 / 4096` is refused and `1 / 32` is accepted.

## Example

The module `ReplicatedStorage.Net.schema`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local t = Lync.types

local position = t.vector3(-2048, 2048, 1 / 4096)
```

raises:

```example
ReplicatedStorage.Net.schema:5: [Lync] vectorStep: t.vector3 step must be above 0.000244140625, the f32 spacing at max(|min|, |max|), got 0.000244140625
```

## Fix

Use a larger step, or narrower bounds.
