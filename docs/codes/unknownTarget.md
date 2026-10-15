---
family: caller
since: 5.0.0
---

# unknownTarget

A server send's target is none of `Target`'s forms: a `Player`, an array of players, a `Lync.group()`,
`Lync.all` or `Lync.except(target)` (v5.md §3.5). Nothing is sent. Unit F raises it; until its views land, the
registry does not run this trigger.

## Example

The module `ServerScriptService.Main`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local t = Lync.types

local net = Lync.server(Lync.schema("arena", {
	announce = Lync.event({ from = "server", data = t.string(200) }),
}))
net.announce:fire("everyone", "round 3")
```

raises:

```example
ServerScriptService.Main:8: [Lync] unknownTarget: arena.announce:fire target must be a Player, an array of players, a group, Lync.all or Lync.except(target), got "everyone"
```

## Fix

Pass one of the target forms; `Lync.all` reaches every player.
