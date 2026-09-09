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

One namespace with all three primitives.

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

The server and client code for this namespace.

=== "Server"

    ```lua
    Net.Strike:onServer(function(position, player)
        resolveHit(player, position)
    end)

    Net.Sell:onServer(function(request, player)
        return { earned = price(request.item) }
    end)

    Net.Fighters:add(userId, { name = "Ada", team = "red", score = 0, pos = at })

    Lync.start()
    RunService.PostSimulation:Connect(Lync.flush)
    ```

=== "Client"

    ```lua
    Net.Fighters:onChanged(function(id, record, old)
        board:set(id, record.score)
    end)

    Lync.start()
    RunService.PostSimulation:Connect(Lync.flush)

    Net.Strike:fireServer(aim())

    local ok, receipt = Net.Sell:request({ item = "sword" })
    if ok then
        wallet:add(receipt.earned)
    end
    ```

`record.score` and `receipt.earned` are typed as `number` without any annotation.

| | | |
| --- | --- | --- |
| [Setup](guide/index.md) | Installing, the shared definition module, wiring both sides. | |
| [Packets](guide/packets.md) | One way messages, delivery modes, recipients. | |
| [Queries](guide/queries.md) | Requests and replies, and how a request can end without one. | |
| [Sets](guide/sets.md) | Server owned records replicated to the clients allowed to see them. | |
| [Codecs](reference/codecs.md) | Every value type and its size on the wire. | |
