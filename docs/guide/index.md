# Getting started

How to install Lync, declare a schema, and wire the server and client.

## Install

=== "Wally"

    ```toml
    [dependencies]
    Lync = "axp3cter/lync@4.0.2"
    ```

=== "npm"

    ```bash
    npm install @axpecter/lync
    ```

    Then see [roblox-ts](../reference/roblox-ts.md) for the `tsconfig.json` change.

=== "Model"

    Take `Lync.rbxm` from the [latest release](https://github.com/Axp3cter/Lync/releases) and
    place it in `ReplicatedStorage`.

## Declare a namespace

Every definition lives in a namespace. Declare it with `define`, in a module the server and every
client require.

```lua title="ReplicatedStorage/Net.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Lync)

return Lync.define("lobby", {
    Ping = Lync.packet(Lync.empty()),
    Notice = Lync.packet(Lync.str(1, 200)),
})
```

- The name is how the two sides find each other. Each namespace gets its own remotes.
- `define` returns the same table, frozen.
- When a client joins, its schema is compared with the server's. A client whose schema differs is
  refused with an error.

A game can have one namespace or several. Separate namespaces can be [flushed on their own
schedules](lifecycle.md#one-namespace-at-a-time).

## Wire both sides

Each side attaches its listeners, calls `start` once, and calls `flush` every frame.

```lua title="ServerScriptService/Net.server.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lync = require(ReplicatedStorage.Lync)
local Net = require(ReplicatedStorage.Net)

Net.Ping:onServer(function(_, player)
    Net.Notice:fireClient(player, "pong")
end)

Lync.start()
RunService.PostSimulation:Connect(function()
    Lync.flush()
end)
game:BindToClose(Lync.close)
```

```lua title="StarterPlayerScripts/Net.client.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lync = require(ReplicatedStorage.Lync)
local Net = require(ReplicatedStorage.Net)

Net.Notice:onClient(function(text)
    print(text)
end)

Lync.start()
RunService.PostSimulation:Connect(function()
    Lync.flush()
end)

Net.Ping:fireServer()
```

## The order of things

| Rule | Why |
| --- | --- |
| Require every module that calls `define` before `start`. | `start` opens the namespaces that exist. A `define` after it throws. |
| Register query responders before `start`. | `start` seals them. Packet and set listeners can attach at any time. |
| Send after `start`. | Fires, requests, set writes and audiences throw before it. |
| Flush every frame, from your own function. | Nothing is sent until a flush. A signal connected to `flush` directly passes the frame time, which `flush` reads as a byte budget and refuses. |
| Bind `close` on the server only. | `BindToClose` is a server API. A client needs no shutdown call. |

[Lifecycle](lifecycle.md) covers `start`, `flush` and `close` in full. The rest of the guide
assumes both sides are wired as above, and marks the lines that must run after `start`.
