# Queries

A query sends a request and returns the reply.

The first codec is the request, the second the reply.

```lua
Sell = Lync.query(
    Lync.struct({ item = Lync.enum({ "sword", "shield" }) }),
    Lync.struct({ sold = Lync.bool(), earned = Lync.int(0, 1000000) })
),
```

The server registers one responder. Its return value is sent back as the reply.

```lua
Net.Sell:onServer(function(request, player)
    if not inventory:has(player, request.item) then
        return { sold = false, earned = 0 }
    end
    local earned = inventory:sell(player, request.item)
    return { sold = true, earned = earned }
end)
```

On the client, `request` yields until a reply arrives or the request ends for another reason.

```lua
local ok, reply, detail = Net.Sell:request({ item = "sword" }, 3)
if ok and reply.sold then
    wallet:add(reply.earned)
end
```

The server can also send requests to a client. It passes a callback instead of yielding.

```lua
Net.Confirm:request(player, { text = "rematch?" }, function(ok, reply, detail)
    if ok then
        lobby:answer(player, reply.yes)
    end
end)
```

| Side | Call | |
| --- | --- | --- |
| client | `request(value, timeout?)` | Yields. Returns `ok, reply, detail`. |
| server | `request(client, value, fn, timeout?)` | `fn(ok, reply, detail)` on completion. |
| server | `onServer(fn)` | The single responder. Registering a second one throws. |
| client | `onClient(fn)` | The single responder for requests sent by the server. |

The timeout is in seconds and defaults to 10. Responders may yield. Each runs on its own thread,
and the reply is sent when it returns. If a responder returns a value the reply codec rejects, the
error is logged and the request ends with the `unanswered` code.

## Endings

A request that gets no reply does not throw. Instead `ok` is false, `reply` is one of four codes,
and `detail.elapsed` is the time waited in seconds.

| `reply` | When |
| --- | --- |
| `"timeout"` | No reply arrived before the deadline. A request rejected by validation on the other side also ends this way. |
| `"unanswered"` | The other side has no responder registered, or its responder threw. |
| `"leave"` | The player on the other side left the game. |
| `"shutdown"` | `Lync.close()` ran before the reply. |

The `sold` field in the example is part of the reply, not one of these codes. Put application
level failures, such as a missing item, in the reply codec so the client can read them.
