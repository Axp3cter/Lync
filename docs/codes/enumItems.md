---
family: declaration
since: 5.0.0
---

# enumItems

`t.enum` takes a list of 1 to 65,535 strings of at most 65,535 bytes each, or a Roblox Enum such as
`Enum.Material` (v5.md §3.3). A table with keys other than 1 to n is not a list.

## Example

The module `ReplicatedStorage.Net.schema`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local t = Lync.types

local phase = t.enum({})
```

raises:

```example
ReplicatedStorage.Net.schema:5: [Lync] enumItems: t.enum items must hold 1 to 65535 names, got 0
```

## Fix

List the names, in the order that fixes their indices.
