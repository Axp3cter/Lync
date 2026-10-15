# Errors and logging

Lync sorts every failure into one of four kinds and handles each differently.

| Kind | Examples | Handling |
| --- | --- | --- |
| Your mistake | A send before `start`, the other side's send call, a second responder, an undeclared field, a value that doesn't fit | Throws at the call. |
| Dropped input | A value its codec or a `:validate` refused | Logged, not thrown. |
| A fault in your code | A listener or responder that throws | Logged with a stack trace. Other listeners still run. |
| Transport | A timeout, a player leaving, a shutdown | Returned as a [request outcome](queries.md#when-there-is-no-reply). |

Registering a listener for the other side, such as `onServer` on a client, logs a warning and
attaches nothing. So one shared module can register both sides' listeners.

## onLog

All log output goes through `onLog`. Branch on the fields of `data`, not on the message, which can
change between versions.

```lua
Lync.onLog(function(kind, message, data)
    if data.code == "drop.validate" and data.player ~= nil then
        print("suspicious", data.player, data.reason)
    end
end)
```

| Argument | Holds |
| --- | --- |
| `kind` | `"warn"` or `"error"`. A drop on the server is a warning. A drop on a client, or a fault, is an error. |
| `message` | The text the default printer writes. |
| `data.file`, `data.line` | Where the definition was declared, or a place inside Lync when no definition is involved. Always present. |
| `data.player` | The sender, when there is one. |
| `data.definition` | The definition, when there is one. |
| `data.code` | For a drop, which kind. See below. |

## Codes

| `data.code` | Means | Extra fields |
| --- | --- | --- |
| `drop.validate` | A `:validate` refused the value. | `reason`, `path` |
| `drop.tag`, `drop.count`, `drop.varint`, `drop.pad`, `drop.map-order`, `drop.sidecar` | A value broke its codec's bounds. | `path`, `expected`, `got` |
| `drop.bounds`, `drop.section`, `drop.defid` | A frame was malformed. | `said` or `expected`, `got` |
| `drop.hello` | The handshake remote carried something that is not a handshake. | |
| `drop.unready` | A client received more early frames than it holds while joining. | |
| `drop.mismatch` | The two sides' schemas differ. | `ours`, `theirs` |

When a client passes the drop limit, the extra drops of one code become a single record with
`data.suppressed`, the number left unrecorded. It is logged when the 10-second window reopens or
the player leaves.

## The console

`Lync.console` is the built-in listener that prints to the output. Disconnect it to handle records
yourself.

```lua
Lync.console:disconnect()
```

## Connections

Every `on*` method except a query responder returns a connection.

```lua
local connection = Net.Notice:onClient(function(text)
    print(text)
end)

connection:disconnect()
```
