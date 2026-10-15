---
family: caller
since: 5.0.0
---

# wrongSide

A view's member that exists only on the other side was used: a client-sent event fired on the server, a
server-sent one connected on the client, and so on. On the runtime path the view's metatable miss raises it, at
no cost to the members that exist (v5.md §3.5); on the generated path it is a type error. Unit F raises it; until
its views land, the registry does not run this trigger.

## Example

The module `ServerScriptService.Main`:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Packages.Lync)
local t = Lync.types

local net = Lync.server(Lync.schema("arena", {
	chat = Lync.event({ from = "client", data = t.string(200) }),
}))
net.chat:fire("gg")
```

raises:

```example
ServerScriptService.Main:8: [Lync] wrongSide: arena.chat:fire must be called on the client, got "server"
```

## Fix

Call the member on the side that has it; the server receives `chat` with `connect`.
