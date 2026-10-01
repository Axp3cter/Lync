# Queries

A query sends a request and gets one reply. The first codec is the request, the second the reply.

```lua
Sell = Lync.query(
    Lync.struct({ item = Lync.enum({ "sword", "shield" }) }),
    Lync.struct({ sold = Lync.bool(), earned = Lync.int(0, 1000000) })
),
```

## Answer

The answering side registers one responder, before `start`. What it returns is the reply.

```lua
local PRICES = { sword = 100, shield = 60 }

Net.Sell:onServer(function(request, player)
    return { sold = true, earned = PRICES[request.item] }
end)
```

Each request runs its responder on its own thread, so a responder may yield. The reply is sent
when it returns.

## Ask

A client's `request` yields until the reply arrives or the request ends.

```lua
-- After Lync.start():
local ok, reply = Net.Sell:request({ item = "sword" })
if ok and reply.sold then
    print("earned", reply.earned)
end
```

The server can ask one client. It cannot yield on a client, so it passes a callback.

```lua
-- After Lync.start():
Net.Confirm:request(player, { text = "rematch?" }, function(ok, reply)
    if ok then
        print(player.Name, reply.yes)
    end
end)
```

- Both forms take an optional timeout in seconds as the last argument. The default is 10.
- The request value is checked at the call, which throws if it doesn't fit.
- Only the asked player's answer counts. A reply from anyone else is ignored.

## When there is no reply

A request never throws once sent. If it ends without a reply, `ok` is false, `reply` is one of
four codes, and the third value, `detail`, holds `elapsed`, the seconds waited.

| `reply` | When |
| --- | --- |
| `"timeout"` | No reply in time. A request dropped by the other side's validation ends this way. |
| `"unanswered"` | No responder, a responder that threw or returned a value the reply codec refuses, a client still joining, or a client with too many requests running. |
| `"leave"` | The player on the other side left. |
| `"shutdown"` | `Lync.close()` ran first. |

These codes report transport failures. Put your game's failures, such as a missing item, in the
reply codec, like `sold` above, so the asker can read them.

A client may have 64 requests running at once in each namespace. See
[Limits](../reference/limits.md#requests).
