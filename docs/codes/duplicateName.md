---
family: declaration
since: 5.0.0
---

# duplicateName

A list enum names the same item twice. Each item's index is its place in the list, so a repeated
name would have two indices.

## Example

The module `ReplicatedStorage.Net.schema`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local t = Lync.types

local team = t.enum({ "red", "blue", "red" })
```

raises:

```example
ReplicatedStorage.Net.schema:5: [Lync] duplicateName: t.enum items must be distinct, got "red"
```

## Fix

Remove the repeated item.
