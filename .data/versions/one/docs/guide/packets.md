# Packets

A packet carries one value in one direction, with no reply.

## Fire and listen

```lua title="ReplicatedStorage/Net.luau"
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lync = require(ReplicatedStorage.Lync)

return Lync.define("combat", {
    Strike = Lync.packet(Lync.vec3(Lync.quant(-512, 512, 0.1))),
    Hit = Lync.packet(Lync.int(0, 100)),
})
```

=== "Server"

    ```lua
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local Net = require(ReplicatedStorage.Net)

    Net.Strike:onServer(function(position, player)
        Net.Hit:fireClient(player, 25)
    end)
    ```

=== "Client"

    ```lua
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local Net = require(ReplicatedStorage.Net)

    Net.Hit:onClient(function(damage)
        print("took", damage)
    end)

    -- After Lync.start():
    Net.Strike:fireServer(Vector3.new(10, 0, 4))
    ```

- The server fires at any [recipient](recipients.md). A client fires at the server only.
- A server listener receives the sending player after the payload.
- A packet of `empty()` carries nothing. Fire it with no value. Its listener still receives a first
  argument, which is nil.

## What happens to a value

- **At the call.** The value is checked against its codec. A value that doesn't fit throws there,
  naming the field.
- **On arrival.** The value is checked again, then any `:validate` runs. A value that fails is
  dropped and logged. See [Validation](validation.md).
- **In your listeners.** Each runs on its own thread and may yield. A packet can have several. If
  one throws, the error is logged and the rest still run.

A packet that arrives with nothing listening logs a warning. From a client, that warning is logged
once per definition, until a listener attaches.

## Delivery

Packets are reliable and ordered unless you declare otherwise.

| Declaration | Delivery | Use it for |
| --- | --- | --- |
| `packet(c)` | Reliable and ordered. | Anything that must arrive, in order. |
| `packet(c):unreliable()` | Can be lost or reordered. Every fire is sent. | Frequent events where a late copy is useless, such as footsteps. |
| `packet(c):newest(hz?)` | Can be lost. Only the latest value per recipient is sent at a flush. | State that changes every frame, such as aim. |
| `:timestamped()` | Adds `sent` to the listener's arguments. Combines with any of the above. | Values you interpolate or reconcile against time. |

`unreliable` and `newest` cannot be combined. Both use Roblox's unreliable remote, so their worst
case must fit in 1000 bytes. See [Limits](../reference/limits.md#sizes).

### Newest packets

A `newest` packet keeps one value per recipient until the next flush, and sends the latest.

- A value equal to the last one sent to that recipient is skipped.
- `hz` caps how often each recipient is sent a value.
- A recipient is matched by identity. `Lync.all`, a player and a [group](recipients.md#groups) are
  the same recipient each time. A list built fresh at each fire is a new recipient each time, so
  nothing is replaced or skipped.

### Timestamps

`sent` is the time of the fire, on the clock `workspace:GetServerTimeNow()` reads. A client's
claim is clamped on the server to between 60 seconds before arrival and arrival.

## Order

Reliable packets keep their order within a namespace, across definitions. Within one flush, Lync
sends replies first, then requests, then packets, then set changes. So a request can be handled
before a packet fired earlier in the same frame.

Packets fired at a client that has not finished joining are dropped. See
[Recipients](recipients.md#joining).
