# Errors and logging

Failures fall into four classes, and each class is handled differently.

| What | Examples | Handling |
| --- | --- | --- |
| Programmer error | A call on the wrong side, a second responder, a second `start`, a field the record does not declare. | Throws on the spot. |
| Dropped input | A validate reason, a payload the schema rejects. | Logged as a warning. Not thrown. |
| Environmental | A listener or responder that throws. | Logged as an error with a stack trace. Other listeners still run. |
| Transport | A timeout, a player leaving, a shutdown. | Returned as an outcome code. Not thrown. |

All log output goes through `onLog`. Decide what to do from the fields in `data`, not from the
message text, which can change between versions.

```lua
Lync.onLog(function(kind, message, data)
    if data.player ~= nil then
        flagSuspicious(data.player, data)
    end
end)
```

| Argument | |
| --- | --- |
| `kind` | `"warn"` for dropped input, `"error"` for a caught fault. |
| `message` | The text the default printer writes. |
| `data.file`, `data.line` | Where the definition was declared. Always present. |
| `data.player` | Who sent the value, when a sender is involved. |
| `data.definition` | Which definition, when one is involved. |

`Lync.console` is the built-in listener that prints to the output. Disconnect it to handle log
records yourself.

```lua
Lync.console:disconnect()
```

## Connections

Every `on*` returns a connection.

```lua
local connection = Net.Chat:onClient(function(text)
    feed:push(text)
end)

connection:disconnect()
```

When a player leaves, every pending request to or from them ends with the `leave` code.
