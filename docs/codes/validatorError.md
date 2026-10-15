---
family: fault
since: 5.0.0
---

# validatorError

A `validate` function raised (v5.md §6.1 step 6). The message is dropped and counted as a validator error, an
ask is answered `rejected`, and the raise is reported natively, at most once per definition per window (§7.2),
positioned at the validator; its error is given without its position. Unit F raises it; until its validators
land, the registry does not run this trigger.

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
	return player.Team.Name ~= "Spectators" and #text > 0
end)
```

reports natively, when a player without a team sends `chat`:

```example
ServerScriptService.Main:8: [Lync] validatorError: arena.chat validator must return a boolean without raising, got "attempt to index nil with 'Name'"
```

## Fix

Make the validator return `true` or `false` for every value it can receive.
