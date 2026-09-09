# Packets

A packet sends one value in one direction.

Four example packets, one for each delivery mode.

```lua
Strike = Lync.packet(Lync.vec3(Lync.quant(-512, 512, 0.1))):unreliable(),
Aim    = Lync.packet(Lync.rotation.quat(0.2)):newest(20):timestamped(),
Chat   = Lync.packet(Lync.str(1, 200)),
Nudge  = Lync.packet(Lync.empty()),
```

On the server, `fireClient` takes a recipient and a payload, and `onServer` receives the payload
followed by the sending player.

```lua
Net.Chat:fireClient(Lync.all, "round starts")
Net.Chat:fireClient(Lync.except(afk), "ready?")

Net.Strike:onServer(function(position, player)
    resolveHit(player, position)
end)

Net.Aim:onServer(function(rotation, player, sent)
    ghosts[player]:aim(rotation, sent)
end)
```

On the client, `fireServer` takes only the payload, and `onClient` receives only the payload.

```lua
Net.Strike:fireServer(aim())
Net.Nudge:fireServer()

Net.Chat:onClient(function(text)
    feed:push(text)
end)
```

| Side | Call | |
| --- | --- | --- |
| server | `fireClient(to, payload)` | Encoded once however many receive it. |
| server | `onServer(fn)` | `fn(payload, player, sent?)` |
| client | `fireServer(payload)` | |
| client | `onClient(fn)` | `fn(payload, sent?)` |

A packet of `empty()` carries no payload. Fire it with no arguments. The listener still receives
a first argument, which is nil.

## Delivery

Packets are reliable and ordered by default. `:unreliable()` and `:newest()` change how a packet
is delivered, and `:timestamped()` adds the send time to either.

| Declaration | Delivery | Use it for |
| --- | --- | --- |
| `packet(c)` | Reliable, ordered. | Anything that must arrive, exactly once, in order. |
| `packet(c):unreliable()` | May be lost or reordered. Every fire is still sent. Payload under 1 KB. | Frequent events where a late copy has no use, such as footsteps. |
| `packet(c):newest()` | May be lost. Only the latest value is delivered, and an unchanged value is not sent. | State that changes every frame, such as a position. |
| `packet(c):newest(20)` | The same, sent at most 20 times a second. | The same, when the rate needs a cap. |
| `packet(c):timestamped()` | Adds `sent`, the send time on the shared clock. Combines with either of the above. | Values you interpolate or reconcile against time. |

Packets keep their order, both within one definition and between definitions. Requests are not
ordered against packets: a request can be handled before a packet fired earlier in the same
frame.

## Recipients

The `to` argument of `fireClient`, and of a set's `audience`, accepts any of these.

| Recipient | Reaches |
| --- | --- |
| `Lync.all` | Every client. |
| `player` | One client. |
| `{ alice, bob }` | The listed clients. |
| `redTeam` | A [group](lifecycle.md#groups). Its members at the time of the flush. |
| `Lync.except(t)` | Every client except `t`, where `t` is a player, a list, or a group. |

Firing a packet that has no listener on the receiving side logs a warning. Listeners may yield.
If a listener throws, the error is logged and the remaining listeners still run.
