# Lifecycle

The server and each client make the same three calls.

```lua
Lync.start()
RunService.PostSimulation:Connect(function()
    Lync.flush()
end)
game:BindToClose(Lync.close)
```

| Call | |
| --- | --- |
| `Lync.start()` | Locks the definitions and responders and creates the remotes. Call once per side, after every definition. |
| `Lync.flush(budget?)` | Sends everything buffered since the last flush, one frame per client. A flush with nothing buffered costs nothing. |
| `Lync.flush(name, budget?)` | The same for one namespace, on its own cadence. |
| `Lync.close()` | Flushes one last time, ends open requests with the `shutdown` code, and destroys the remotes. |

| Out of order | |
| --- | --- |
| A second `start` | Throws. |
| A flush before `start` | Throws. |
| A second `close` | Does nothing. |
| `flush` connected to a signal directly | Throws. The signal passes the frame time as the first argument, and it is read as a budget under the floor. Connect a function that calls `flush` with no arguments. |

## Budgets

A budget limits how many bytes of set state one flush sends to each client. State beyond the
budget is sent in later flushes, in order. Packets, requests and replies are not limited by it.

| Call | Budget |
| --- | --- |
| `Lync.flush()` | The default, 32 KB per second per client. |
| `Lync.flush(8192)` | At most 8 KB of state per client, every namespace. |
| `Lync.flush("arena", 8192)` | The same for one namespace. |
| `Lync.flush(512)` | Throws. 1024 is the floor. |

!!! note
    Namespaces flush independently of each other. A namespace with latency critical traffic can
    flush every frame while a bulkier one flushes a few times a second with a larger budget.

## Groups

A group is a set of players. It can be passed anywhere a recipient is accepted.

```lua
local redTeam = Lync.group()

redTeam:add(player)
redTeam:remove(player)

if redTeam:has(player) then
    greet(player)
end

for _, member in redTeam do
    greet(member)
end

redTeam:destroy()
```

| Call | |
| --- | --- |
| `add(player)` `remove(player)` | Adding a player twice has no further effect. |
| `has(player)` | |
| `#group` | The number of members. |
| `for _, player in group` | Iteration over them. |
| `destroy()` | Empties the group and frees it. Any call after that throws. |

Players who leave the game are removed from every group. Audiences and `Lync.except` keep a
reference to the group rather than a copy, so a change in membership takes effect on the next
flush without calling `audience` again.
