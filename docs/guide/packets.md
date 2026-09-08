# Packets

One value, one way.

```lua
Strike = Lync.packet(Lync.vec3(Lync.quant(-512, 512, 0.1))):unreliable(),
Aim    = Lync.packet(Lync.rotation.quat(0.2)):newest(20):timestamped(),
Chat   = Lync.packet(Lync.str(1, 200)),
Nudge  = Lync.packet(Lync.empty()),
```

```lua
-- server
Net.Chat:fireClient(Lync.all, "round starts")
Net.Chat:fireClient(Lync.except(afk), "ready?")
Net.Strike:onServer(function(at, player, _) resolveHit(player, at) end)
Net.Aim:onServer(function(turn, player, sent) ghosts[player]:aim(turn, sent) end)

-- client
Net.Strike:fireServer(aim())
Net.Nudge:fireServer()  -- no payload
Net.Chat:onClient(function(line) feed:push(line) end)
```

| Side | Call | |
| --- | --- | --- |
| server | `fireClient(to, payload)` | Encoded once however many receive it. |
| server | `onServer(fn)` | `fn(payload, player, sent?)` |
| client | `fireServer(payload)` | |
| client | `onClient(fn)` | `fn(payload, sent?)` |

## Delivery

```lua
Lync.packet(c)                           -- reliable, ordered
Lync.packet(c):unreliable()              -- lossy, unordered, under 1 KB
Lync.packet(c):newest()                  -- lossy, latest wins, unchanged sends nothing
Lync.packet(c):newest(20)                -- at most 20 a second
Lync.packet(c):newest(20):timestamped()  -- plus `sent`, the sender's instant
```

Order holds within a definition and across packets. A request may still be heard before a packet
fired earlier in the same frame.

## Recipients

```lua
Net.Chat:fireClient(Lync.all, line)             -- everyone
Net.Chat:fireClient(player, line)               -- one
Net.Chat:fireClient({ a, b }, line)             -- a list
Net.Chat:fireClient(redTeam, line)              -- a group, members at send time
Net.Chat:fireClient(Lync.except(player), line)  -- everyone but one, a list, or a group
```

Firing where nothing listens is a warning. A listener may yield, and one that throws is logged
without stopping the others.
