---
family: declaration
since: 5.0.0
---

# missingOption

A required option is absent: `from` on an event or a request, `perSecond` in a `limit`, or `encode`,
`decode`, `name`, `version` and one of `maxBits` and `maxBytes` in a `t.custom` spec.

## Example

The module `ReplicatedStorage.Net.schema`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local t = Lync.types

return Lync.schema("arena", {
	chat = Lync.event({ data = t.string(200) }),
})
```

raises:

```example
ReplicatedStorage.Net.schema:6: [Lync] missingOption: arena.chat must have the option from, "client" or "server"
```

## Fix

Add the option. For `from`, name the side that sends the definition.
