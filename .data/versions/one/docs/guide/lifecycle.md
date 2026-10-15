# Lifecycle

Three calls drive Lync. Both sides call `start` and `flush`. The server also calls `close` on
shutdown.

```lua
local RunService = game:GetService("RunService")

Lync.start()
RunService.PostSimulation:Connect(function()
    Lync.flush()
end)

-- Server only:
game:BindToClose(Lync.close)
```

| Call | Does |
| --- | --- |
| `Lync.start()` | Opens every namespace defined so far: checks and seals the schema, creates the remotes, and on a client, joins the server. Once per side. |
| `Lync.flush(budget?)` | Sends everything queued since the last flush, in every namespace. A flush with nothing queued costs nothing. |
| `Lync.flush(name, budget?)` | The same, for one namespace. |
| `Lync.close()` | Flushes one last time, ends open requests with `"shutdown"`, and destroys the remotes. |

## Queues

Fires, requests and set writes queue when you call them. A flush sends the queue in as few remote
calls per client as it can.

If something is queued and no flush follows within a second, Lync logs an error naming the
definition. That usually means `flush` is not connected.

| Out of order | Result |
| --- | --- |
| A second `start` | Throws. |
| `flush` or `close` before `start` | Throws. |
| A second `close` | Does nothing. |
| Anything sent after `close` | Throws. |
| `flush` connected to a signal directly | Throws, since the signal passes the frame time as the budget. |

## Budgets

A budget caps the bytes of set state one flush sends to each client. State over it waits for later
flushes, in order. Packets, requests and replies are never held back.

| Call | Budget per client |
| --- | --- |
| `Lync.flush()` | 32 KB per second since the last flush, and at least 1024 bytes. |
| `Lync.flush(8192)` | 8 KB, in every namespace. |
| `Lync.flush("world", 8192)` | 8 KB, in `world` only. |
| `Lync.flush(512)` | Throws. The floor is 1024. |

## One namespace at a time

Namespaces flush independently. A namespace with urgent traffic can flush every frame while a
bulky one flushes a few times a second with a larger budget.

```lua
local RunService = game:GetService("RunService")

local elapsed = 0
RunService.PostSimulation:Connect(function(dt)
    Lync.flush("combat")
    elapsed += dt
    if elapsed >= 0.25 then
        elapsed = 0
        Lync.flush("world", 16384)
    end
end)
```
