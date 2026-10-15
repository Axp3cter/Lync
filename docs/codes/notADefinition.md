---
family: declaration
since: 5.0.0
---

# notADefinition

A schema entry was not made by `Lync.event`, `Lync.request` or `Lync.collection`, such as a codec or
an option table given directly.

## Example

The module `ReplicatedStorage.Net.schema`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local t = Lync.types

return Lync.schema("arena", {
	chat = { from = "client", data = t.string(200) },
})
```

raises:

```example
ReplicatedStorage.Net.schema:5: [Lync] notADefinition: arena.chat must be made by Lync.event, Lync.request or Lync.collection, got table (2 keys)
```

## Fix

Wrap the options in `Lync.event`, `Lync.request` or `Lync.collection`.
