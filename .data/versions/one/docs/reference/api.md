# API

Every function and method, grouped by object. Codec constructors are under
[Codecs](codecs.md).

## Lync

### Declaring

| Call | Returns |
| --- | --- |
| `define(name, definitions)` | The same table, frozen, with each definition bound to the namespace `name`. |
| `packet(codec)` | A [packet](../guide/packets.md). |
| `query(request, reply)` | A [query](../guide/queries.md). |
| `replicate(struct)` | A [set](../guide/sets.md). |
| `group()` | A [group](../guide/recipients.md#groups). |

### Running

| Call | Does |
| --- | --- |
| `start()` | Opens every namespace. Once per side. |
| `flush()` | Sends everything queued, in every namespace, at the default budget. |
| `flush(budget)` | The same, with a budget in bytes of set state per client. At least 1024. |
| `flush(name, budget?)` | One namespace only. |
| `close()` | Flushes, ends open requests with `"shutdown"`, and destroys the remotes. |

See [Lifecycle](../guide/lifecycle.md).

### Values

| Member | Is |
| --- | --- |
| `all` | Every client, as a [recipient](../guide/recipients.md). |
| `except(target)` | Every client but a player, a list or a group. |
| `none` | Clears an optional field in a set `update`. |
| `encode(codec, value)` | `bytes, refs?`. The value as an exact-size buffer, and the instances it names when the codec holds `inst`. Throws on a value the codec refuses. |
| `decode(codec, bytes, refs?)` | The value. Runs every `:validate`. Throws on bytes that do not decode or that have bytes left over. |

The bytes from `encode` are not a storage format across Lync versions. See
[Encoding without the network](../guide/codecs.md#encoding-without-the-network).

### Logging

| Member | Is |
| --- | --- |
| `onLog(fn)` | Attaches `fn(kind, message, data)`. Returns a connection. |
| `console` | The built-in printer, as a connection. |

See [Errors and logging](../guide/logging.md).

## Packet

| Call | Side | |
| --- | --- | --- |
| `:unreliable()` | declaration | Lossy and unordered. |
| `:newest(hz?)` | declaration | Lossy, latest value per recipient. |
| `:timestamped()` | declaration | Adds `sent` to the listener's arguments. |
| `:fireServer(value)` | client | |
| `:fireClient(to, value)` | server | |
| `:onServer(fn)` | server | `fn(value, player, sent?)` |
| `:onClient(fn)` | client | `fn(value, sent?)` |
| `:describe()` | either | The schema as text. Equal text means compatible schemas. |

## Query

| Call | Side | |
| --- | --- | --- |
| `:request(value, timeout?)` | client | Yields. Returns `ok, reply, detail`. |
| `:request(player, value, fn, timeout?)` | server | Calls `fn(ok, reply, detail)` once, when it ends. |
| `:onServer(fn)` | server | The responder, `fn(value, player)`. One, before `start`. |
| `:onClient(fn)` | client | The responder, `fn(value)`. One, before `start`. |
| `:describe()` | either | |

## Set

| Call | Side | |
| --- | --- | --- |
| `:keyBy(field)` | declaration | Groups records into audiences by `field`. |
| `:add(id, record)` | server | |
| `:update(id, fields)` | server | |
| `:remove(id)` | server | |
| `:clear()` | server | |
| `:audience(key, to)` | server | Keyed sets only. |
| `:get(id)` | either | The live record, or nil. |
| `:size()` | either | Same as `#set`. |
| `:entries()` | either | Same as `for id, record in set`. |
| `:onAdded(fn)` | either | `fn(id, record)` |
| `:onChanged(fn)` | either | `fn(id, record, old)` |
| `:onRemoved(fn)` | either | `fn(id, cause)` |
| `:describe()` | either | |

## Group

| Call | |
| --- | --- |
| `:add(player)` | |
| `:remove(player)` | |
| `:has(player)` | |
| `:size()` | Same as `#group`. |
| `:players()` | Same as `for _, player in group`. |
| `:destroy()` | Empties the group. Any later use throws. |

## Connection

| Member | |
| --- | --- |
| `.connected` | Whether it is still attached. |
| `:disconnect()` | Detaches the handler. Calling it again does nothing. |
