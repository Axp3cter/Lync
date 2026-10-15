---
family: fault
since: 5.0.0
---

# validatorYielded

A `validate` function yielded (v5.md §6.1 step 6), detected by a re-entrancy flag. The message is dropped and
counted, an ask is answered `rejected`, and the yield is reported natively, at most once per definition per window
(§7.2), positioned at the validator. Unit F raises it; until its validators land, the registry does not run this
trigger.

## Example

The module `ServerScriptService.Main`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local t = Lync.types

local net = Lync.server(Lync.schema("arena", {
	chat = Lync.event({ from = "client", data = t.string(200) }),
}))
net.chat:validate(function(player, text)
	task.wait(1)
	return #text > 0
end)
```

reports natively, when a player sends `chat`:

```example
ServerScriptService.Main:8: [Lync] validatorYielded: arena.chat validator must return without yielding
```

## Fix

Decide in the validator without waiting; do slow checks in `connect`.
