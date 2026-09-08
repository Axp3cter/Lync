---
hide:
  - navigation
  - toc
---

# Lync

Lync is a networking library for Roblox. You describe each packet, query and replicated set once,
as a schema of codecs, and both the server and the client require that one module. A value sent
from one side is decoded by the same definition on the other, and its Luau type is inferred from
the schema, so handlers, records and replies are typed without annotations. Every value is packed
at the bit, an `int(0, 100)` costs seven bits, and everything sent during a frame is batched into
one remote call per client when you flush.

```lua title="ReplicatedStorage/Net.luau"
return Lync.define("arena", {
    Strike = Lync.packet(Lync.vec3(Lync.quant(-512, 512, 0.1))):unreliable(),

    Sell = Lync.query(
        Lync.struct({ item = Lync.enum({ "sword", "shield" }) }),
        Lync.struct({ earned = Lync.int(0, 1000000) })
    ),

    Fighters = Lync.replicate(Lync.struct({
        name  = Lync.str(1, 20),
        team  = Lync.enum({ "red", "blue" }),
        score = Lync.int(0, 1000000),
        pos   = Lync.vec3(Lync.quant(-512, 512, 0.1)):newest(10),
    })):keyBy("team"),
})
```

=== "Server"

    ```lua
    Net.Strike:onServer(function(at, player) end)
    Net.Sell:onServer(function(order, player) return { earned = 25 } end)
    Net.Fighters:add(id, { name = "Ada", team = "red", score = 0, pos = Vector3.zero })

    Lync.start()
    RunService.PostSimulation:Connect(Lync.flush)
    ```

=== "Client"

    ```lua
    Net.Fighters:onChanged(function(id, record, old) board(id, record.score) end)

    Lync.start()
    RunService.PostSimulation:Connect(Lync.flush)

    Net.Strike:fireServer(aim())
    local ok, receipt = Net.Sell:request({ item = "sword" })  -- receipt.earned: number
    ```

[Setup](guide/index.md){ .md-button .md-button--primary }
[Codecs](reference/codecs.md){ .md-button }
