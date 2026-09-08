# Errors and logging

```lua
Lync.onLog(function(kind, message, data)
    -- kind     "warn" for something dropped, "error" for a fault contained
    -- data     file, line, and when present player and definition
    if data.player ~= nil then flagSuspicious(data.player, data) end
end)

Lync.console:disconnect()  -- the default printer is a connection like any other
```

Match on `data`, never on the message.

| | | |
| --- | --- | --- |
| Programmer error | A call on the wrong side, a second responder, a second `start`. | Throws on the spot. |
| Dropped input | A validate reason, a payload the schema turns away. | Warning. |
| Environmental | A listener or responder that throws. | Error with its trace. The rest continue. |
| Transport | Timeout, a leaver, shutdown. | An outcome code, never a throw. |

```lua
local conn = Net.Chat:onClient(function(line) end)
conn:disconnect()  -- every on* returns one
```

When a player leaves, each pending request touching them ends as `leave`.
