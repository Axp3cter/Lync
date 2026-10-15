---
hide:
  - navigation
  - toc
---

# Lync

Typed buffer networking for Roblox, in Luau and roblox-ts.

You declare packets, queries and replicated sets once, in a module both sides require. Lync packs
every value to the bit from that schema and infers your handler types from it. Everything sent in
a frame is batched per client when you flush.

```lua title="ReplicatedStorage/Net.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Lync)

return Lync.define("game", {
    Chat = Lync.packet(Lync.str(1, 200)),

    Sell = Lync.query(Lync.enum({ "sword", "shield" }), Lync.int(0, 1000)),

    Scores = Lync.replicate(Lync.struct({
        name = Lync.str(1, 20),
        score = Lync.int(0, 1000000),
    })),
})
```

=== "Server"

    ```lua
    local Players = game:GetService("Players")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local RunService = game:GetService("RunService")
    local Lync = require(ReplicatedStorage.Lync)
    local Net = require(ReplicatedStorage.Net)

    local PRICES = { sword = 100, shield = 60 }

    Net.Chat:onServer(function(text, player)
        Net.Chat:fireClient(Lync.except(player), text)
    end)

    Net.Sell:onServer(function(item, player)
        return PRICES[item]
    end)

    Lync.start()
    RunService.PostSimulation:Connect(function()
        Lync.flush()
    end)
    game:BindToClose(Lync.close)

    local function joined(player: Player)
        Net.Scores:add(player.UserId, { name = player.Name, score = 0 })
    end

    Players.PlayerAdded:Connect(joined)
    for _, player in Players:GetPlayers() do
        joined(player)
    end
    Players.PlayerRemoving:Connect(function(player)
        Net.Scores:remove(player.UserId)
    end)
    ```

=== "Client"

    ```lua
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local RunService = game:GetService("RunService")
    local Lync = require(ReplicatedStorage.Lync)
    local Net = require(ReplicatedStorage.Net)

    Net.Chat:onClient(function(text)
        print(text)
    end)

    Net.Scores:onChanged(function(id, record)
        print(record.name, record.score)
    end)

    Lync.start()
    RunService.PostSimulation:Connect(function()
        Lync.flush()
    end)

    Net.Chat:fireServer("hello")

    local ok, price = Net.Sell:request("sword")
    if ok then
        print("sold for", price)
    end
    ```

`record.score` is typed `number` with no annotation, because the schema says so.

## Where to go

| Page | Answers |
| --- | --- |
| [Getting started](guide/index.md) | How do I install Lync and wire both sides? |
| [Codecs](guide/codecs.md) | How do I describe a value, and what does it cost? |
| [Packets](guide/packets.md) | How do I send a one-way message? |
| [Queries](guide/queries.md) | How do I ask for an answer? |
| [Sets](guide/sets.md) | How do I replicate state, and to whom? |
| [Limits](reference/limits.md) | What can't I do, and what can I change? |
