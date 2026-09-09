# Setup

## Install

=== "Wally"

    ```toml
    [dependencies]
    Lync = "axp3cter/lync@4.0.1"
    ```

=== "npm"

    ```bash
    npm install @axpecter/lync
    ```

=== "Model"

    Take `Lync.rbxm` from the [latest release](https://github.com/Axp3cter/Lync/releases) and
    place it in `ReplicatedStorage`.

## One module, both sides

Put every definition in one module and require that module from the server and from every
client.

```lua title="ReplicatedStorage/Net.luau"
local Lync = require(game.ReplicatedStorage.Lync)

return Lync.define("arena", {
    Ping = Lync.packet(Lync.empty()),
    Chat = Lync.packet(Lync.str(1, 200)),
})
```

On the server, attach listeners, call `start`, and connect `flush` to a fixed step.

```lua title="ServerScriptService/Net.server.luau"
local Lync = require(game.ReplicatedStorage.Lync)
local Net = require(game.ReplicatedStorage.Net)

-- An empty payload arrives as nil, so the player is the second argument.
Net.Ping:onServer(function(_, player)
    Net.Chat:fireClient(player, "pong")
end)

Lync.start()
RunService.PostSimulation:Connect(Lync.flush)
game:BindToClose(Lync.close)
```

The client is wired the same way.

```lua title="StarterPlayerScripts/Net.client.luau"
local Lync = require(game.ReplicatedStorage.Lync)
local Net = require(game.ReplicatedStorage.Net)

Net.Chat:onClient(function(text)
    print(text)
end)

Lync.start()
RunService.PostSimulation:Connect(Lync.flush)

Net.Ping:fireServer()
```

Rules that apply to every setup.

| | |
| --- | --- |
| `start` runs once per side | Call it after the last definition. Adding a definition or responder after it throws. |
| Nothing is sent without `flush` | Fires, requests and set changes are buffered until the next flush. |
| The bootstrap is the same on both sides | If you have a shared startup module, put `start`, the flush connection and `close` there. |

## Bounds are the compression

Every codec is bounded, and the bound decides how many bits a value takes. Pick bounds that match
the ranges the game actually uses.

| Codec | Bits | |
| --- | --- | --- |
| `Lync.f32()` | 32 | Any float. |
| `Lync.int(0, 100)` | 7 | 101 throws on send and drops on arrival. |
| `Lync.quant(0, 1, 0.01)` | 7 | Rounded to the nearest 0.01. |
| `Lync.bool()` | 1 | |
| `Lync.bitfield({ "a", "b", "c" })` | 3 | Three flags as one table. |

All codecs are listed under [Codecs](../reference/codecs.md).
