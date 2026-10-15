---
family: declaration
since: 5.0.0
---

# unknownOption

A definition, a `limit` table or a `t.custom` spec has an option its kind does not take, usually a
misspelled one. Server-sent events and requests do not take `limit`, which throttles what clients
send. The options of each kind are in v5.md §3.4.

## Example

The module `ReplicatedStorage.Net.schema`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local t = Lync.types

return Lync.schema("arena", {
	chat = Lync.event({ from = "client", data = t.string(200), rtae = 5 }),
})
```

raises:

```example
ReplicatedStorage.Net.schema:6: [Lync] unknownOption: arena.chat must have only the options from, data, lane and limit, got "rtae"
```

## Fix

Correct the option's name, or remove it.
