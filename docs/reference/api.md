# API

## Lync

| | |
| --- | --- |
| `define(name, defs)` | A namespace. Returns `defs` with each definition bound. |
| `packet(codec)` `query(request, reply)` `replicate(codec)` | Definitions. |
| `group()` | A membership set. |
| `all` `except(t)` `none` | Every client, everyone but `t`, the clear sentinel for `update`. |
| `start()` `flush(name?, budget?)` `close()` | See [Lifecycle](../guide/lifecycle.md). |
| `onLog(fn)` `console` | Log listener and the default printer, both connections. |

## Packet

| | | |
| --- | --- | --- |
| `:unreliable()` `:newest(hz?)` `:timestamped()` | declaration | Delivery. |
| `:fireServer(payload)` | client | |
| `:fireClient(to, payload)` | server | |
| `:onServer(fn)` `:onClient(fn)` | | `fn(payload, player?, sent?)` |
| `:describe()` | | The canonical schema text. |

## Query

| | | |
| --- | --- | --- |
| `:request(value, timeout?)` | client | Yields. `ok, res, data` |
| `:request(client, value, fn, timeout?)` | server | `fn(ok, res, data)` |
| `:onServer(fn)` `:onClient(fn)` | | The one responder. |
| `:describe()` | | |

## Set

| | | |
| --- | --- | --- |
| `:keyBy(field)` | declaration | Audiences split on `field`. |
| `:add(id, record)` `:update(id, fields)` `:remove(id)` `:clear()` | server | |
| `:audience(key, to)` | server | Keyed sets only. |
| `:get(id)` `:size()` `:entries()` | | Live record, count, iterator. `#set` and `for id, r in set` do the same. |
| `:onAdded(fn)` `:onChanged(fn)` `:onRemoved(fn)` | | `fn(id, record)`, `fn(id, record, old)`, `fn(id, cause)` |
| `:describe()` | | |

## Group

| | |
| --- | --- |
| `:add(player)` `:remove(player)` `:has(player)` | |
| `:size()` `:players()` | Count and iterator. `#group` and `for _, p in group` do the same. |
| `:destroy()` | Empties and releases. Any later use throws. |

## Connection

| | |
| --- | --- |
| `.connected` | |
| `:disconnect()` | Idempotent. |
