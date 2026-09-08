# Lifecycle

```lua
Lync.start()                                   -- once per side, after every definition
RunService.PostSimulation:Connect(Lync.flush)  -- one frame per client
game:BindToClose(Lync.close)                   -- open requests end as "shutdown"
```

A second `start` throws. A flush before `start` throws. A second `close` does nothing.

## Budgets

```lua
Lync.flush(8192)           -- every namespace, at most 8 KB of set state per client
Lync.flush("arena", 8192)  -- one namespace, on its own cadence
Lync.flush("bulk")         -- default budget, 32 KB per second per client
```

A budget throttles set state only. Packets and requests always send in full. State over the
budget waits for the next flush, in order. Under 1024 throws.

!!! note
    Namespaces never queue behind each other. Flush a latency critical one every frame and a bulk
    one a few times a second.

## Groups

```lua
local red = Lync.group()
red:add(player)
red:remove(player)
red:has(player)
for _, member in red do end  -- #red
red:destroy()                -- any later use throws
```

A group goes anywhere a recipient does and thins out as players leave. Audiences and `except`
hold the group itself.
