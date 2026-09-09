# API

All methods, grouped by object. The guide pages show them in use.

## Lync

| Call | |
| --- | --- |
| `define(name, definitions)` | Creates a namespace. Returns the same table with each definition bound to it. |
| `packet(codec)` | An event one way. See [Packets](../guide/packets.md). |
| `query(request, reply)` | A request and its reply. See [Queries](../guide/queries.md). |
| `replicate(codec)` | Server owned records. See [Sets](../guide/sets.md). |
| `group()` | A membership set. See [Groups](../guide/lifecycle.md#groups). |
| `all` | Every client, as a recipient. |
| `except(target)` | Everyone but a player, a list, or a group. |
| `none` | The sentinel that clears an optional field in `update`. |
| `start()` `flush(name?, budget?)` `close()` | See [Lifecycle](../guide/lifecycle.md). |
| `onLog(fn)` | The log listener. Returns a connection. |
| `console` | The built-in log listener that prints to the output. A connection. |

## Packet

| Call | Side | |
| --- | --- | --- |
| `:unreliable()` `:newest(hz?)` `:timestamped()` | declaration | Delivery. |
| `:fireServer(payload)` | client | |
| `:fireClient(to, payload)` | server | |
| `:onServer(fn)` | server | `fn(payload, player, sent?)` |
| `:onClient(fn)` | client | `fn(payload, sent?)` |
| `:describe()` | either | The schema as text. Two schemas with the same text are compatible. |

## Query

| Call | Side | |
| --- | --- | --- |
| `:request(value, timeout?)` | client | Yields. Returns `ok, reply, detail`. |
| `:request(client, value, fn, timeout?)` | server | `fn(ok, reply, detail)` on completion. |
| `:onServer(fn)` `:onClient(fn)` | either | The one responder for that side. |
| `:describe()` | either | |

## Set

| Call | Side | |
| --- | --- | --- |
| `:keyBy(field)` | declaration | Audiences split on `field`. |
| `:add(id, record)` `:update(id, fields)` `:remove(id)` `:clear()` | server | |
| `:audience(key, to)` | server | Keyed sets only. |
| `:get(id)` | either | The live record or nil. |
| `:size()` `:entries()` | either | Count and iterator. `#set` and `for id, record in set` do the same. |
| `:onAdded(fn)` | either | `fn(id, record)` |
| `:onChanged(fn)` | either | `fn(id, record, old)` |
| `:onRemoved(fn)` | either | `fn(id, cause)` |
| `:describe()` | either | |

## Group

| Call | |
| --- | --- |
| `:add(player)` `:remove(player)` `:has(player)` | |
| `:size()` `:players()` | Count and iterator. `#group` and `for _, player in group` do the same. |
| `:destroy()` | Empties and releases. Any later use throws. |

## Connection

| Member | |
| --- | --- |
| `.connected` | Whether it is still attached. |
| `:disconnect()` | Detaches the handler. Calling it more than once has no further effect. |
