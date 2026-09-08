# Queries

A request and its reply.

```lua
Sell = Lync.query(
    Lync.struct({ item = Lync.enum({ "sword", "shield" }) }),           -- request
    Lync.struct({ sold = Lync.bool(), earned = Lync.int(0, 1000000) })  -- reply
),
```

```lua
-- server: one responder, its return value is the reply
Net.Sell:onServer(function(order, player)
    if not inventory:has(player, order.item) then
        return { sold = false, earned = 0 }
    end
    return { sold = true, earned = inventory:sell(player, order.item) }
end)

-- client: yields until the reply or an ending
local ok, res, data = Net.Sell:request({ item = "sword" }, 3)  -- 3 s, default 10
if ok and res.sold then wallet:add(res.earned) end
```

```lua
-- server asking a client: a callback, never a yield
Net.Confirm:request(player, { text = "rematch?" }, function(ok, res, data)
    if ok then lobby:answer(player, res.yes) end
end)
```

| Side | Call | |
| --- | --- | --- |
| client | `request(value, timeout?)` | Yields. |
| server | `request(client, value, fn, timeout?)` | `fn(ok, res, data)` on completion. |
| server | `onServer(fn)` | The one responder. A second throws. |
| client | `onClient(fn)` | The one responder. |

## Endings

Nothing raises. With `ok` false, `res` is a code and `data.elapsed` the wait.

```lua
"timeout"     -- no reply by the deadline, which is also where a validation drop lands
"unanswered"  -- no responder on the other side
"leave"       -- the counterparty left
"shutdown"    -- close ran first
```

`sold` above is not an ending. A domain failure belongs in the reply codec.
