# Setup

=== "Wally"

    ```toml
    [dependencies]
    Lync = "axp3cter/lync@4.0.0"
    ```

=== "npm"

    ```bash
    npm install @axpecter/lync
    ```

=== "Model"

    `Lync.rbxm` from the [latest release](https://github.com/Axp3cter/Lync/releases), placed in
    `ReplicatedStorage`.

## One module, both sides

```lua title="ReplicatedStorage/Net.luau"
local Lync = require(game.ReplicatedStorage.Lync)

return Lync.define("arena", {
    Ping = Lync.packet(Lync.empty()),
    Chat = Lync.packet(Lync.str(1, 200)),
})
```

```lua title="ServerScriptService/Net.server.luau"
local Lync = require(game.ReplicatedStorage.Lync)
local Net = require(game.ReplicatedStorage.Net)

Net.Ping:onServer(function(_, player)          -- an empty payload arrives as nil
    Net.Chat:fireClient(player, "pong")
end)

Lync.start()                                   -- once, after every definition
RunService.PostSimulation:Connect(Lync.flush)  -- nothing sends without a flush
game:BindToClose(Lync.close)
```

```lua title="StarterPlayerScripts/Net.client.luau"
local Lync = require(game.ReplicatedStorage.Lync)
local Net = require(game.ReplicatedStorage.Net)

Net.Chat:onClient(function(line) print(line) end)

Lync.start()
RunService.PostSimulation:Connect(Lync.flush)

Net.Ping:fireServer()
```

## Bounds are the compression

```lua
Lync.f32()                        -- 32 bits
Lync.int(0, 100)                  --  7 bits, 101 throws on send and drops on arrival
Lync.quant(0, 1, 0.01)            --  7 bits, rounded to the nearest 0.01
Lync.bool()                       --  1 bit
Lync.bitfield({ "a", "b", "c" })  -- 3 bits, as one table of flags
```
