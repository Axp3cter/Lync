<h1 align="center">Lync</h1>
<p align="center">Buffer networking for Roblox with delta compression, XOR framing, and built-in security.</p>
<p align="center">
  <a href="https://github.com/Axp3cter/Lync/releases/latest">Releases</a> ·
  <a href="#benchmarks">Benchmarks</a> ·
  <a href="#limits--configuration">Limits</a>
</p>

## Install

```toml
[dependencies]
Lync = "axpecter/lync@0.6.0-alpha"
```

Or grab the `.rbxm` from [releases](https://github.com/Axp3cter/Lync/releases/latest). Place in `ReplicatedStorage`.

> [!IMPORTANT]
> All definitions must happen before `Lync.start()`.

## Lifecycle

| Function | Description |
|:---------|:------------|
| `Lync.start()` | Initializes transport. Server creates remotes, client connects. Call once after all definitions. |
| `Lync.version` | `"0.6.0-alpha"` |

## Packets

`Lync.definePacket(name, config)` → Packet

| Config field | Type | Required | Description |
|:-------------|:-----|:--------:|:------------|
| `value` | Codec | Yes | Serialization codec for the payload. |
| `unreliable` | boolean | No | Use UnreliableRemoteEvent. Default `false`. Cannot combine with delta codecs. |
| `rateLimit` | `{ maxPerSecond, burstAllowance? }` | No | Server-side token bucket. Burst defaults to maxPerSecond. |
| `validate` | `(data, player) → (bool, string?)` | No | Server-side. Return `false, "reason"` to drop. Runs after NaN scan. |

**Packet methods — Server:**

| Method | Description |
|:-------|:------------|
| `sendTo(data, player)` | Send to one player. |
| `sendToAll(data)` | Send to all players. |
| `sendToAllExcept(data, except)` | Send to all except one. |
| `sendToList(data, players)` | Send to a list of players. |
| `sendToGroup(data, groupName)` | Send to a named group. |

**Packet methods — Client:**

| Method | Description |
|:-------|:------------|
| `send(data)` | Send to server. |

**Packet methods — Both:**

| Method | Description |
|:-------|:------------|
| `listen(fn(data, sender))` | Register a listener. Returns a Connection. `sender` is `Player` on server, `nil` on client. |
| `once(fn(data, sender))` | Listen for one fire, then auto-disconnect. Returns a Connection. |
| `wait()` | Yields until the next fire. Returns `(data, sender)`. |
| `disconnectAll()` | Disconnects all listeners on this packet. |

## Queries

`Lync.defineQuery(name, config)` → Query

| Config field | Type | Required | Description |
|:-------------|:-----|:--------:|:------------|
| `request` | Codec | Yes | Codec for the request payload. |
| `response` | Codec | Yes | Codec for the response payload. |
| `timeout` | number | No | Seconds before returning `nil`. Default `5`. |
| `rateLimit` | `{ maxPerSecond, burstAllowance? }` | No | Server-side token bucket. |
| `validate` | `(data, player) → (bool, string?)` | No | Server-side validation on incoming requests. |

**Query methods:**

| Method | Context | Description |
|:-------|:--------|:------------|
| `listen(fn)` | Both | Register a handler. Server: `fn(request, player) → response`. Client: `fn(request) → response`. Returns a Connection. |
| `invoke(request)` | Client | Send request to server, yield until response. Returns response or `nil` on timeout. |
| `invoke(request, player)` | Server | Send request to a client, yield until response. Returns response or `nil` on timeout. |

| Introspection | Description |
|:--------------|:------------|
| `Lync.queryPendingCount()` | Number of queries currently awaiting a response. |

## Namespaces

`Lync.defineNamespace(name, config)` → Namespace

Config accepts `packets` and `queries` tables. Names are auto-prefixed with `"NamespaceName."`. Access packets and queries by short name on the returned object.

**Namespace methods:**

| Method | Description |
|:-------|:------------|
| `ns.PacketName` | Access a packet by its short name. |
| `ns.QueryName` | Access a query by its short name. |
| `ns:listenAll(fn(name, data, sender))` | Listen to every packet in the namespace. `name` is the short name. Returns a Connection. |
| `ns:onSend(fn(data, name, player) → data?)` | Scoped send middleware. Only fires for this namespace. Returns a remover function. |
| `ns:onReceive(fn(data, name, player) → data?)` | Scoped receive middleware. Only fires for this namespace. Returns a remover function. |
| `ns:disconnectAll()` | Disconnects all listeners created through `listenAll`. |
| `ns:destroy()` | Disconnects all listeners and removes all scoped middleware. |
| `ns:packetNames()` | Returns sorted `{ string }` of packet short names. |
| `ns:queryNames()` | Returns sorted `{ string }` of query short names. |

## Types

### Primitives

| Type | Bytes | Range |
|:-----|------:|:------|
| `u8` | 1 | 0 – 255 |
| `u16` | 2 | 0 – 65,535 |
| `u32` | 4 | 0 – 4,294,967,295 |
| `i8` | 1 | -128 – 127 |
| `i16` | 2 | -32,768 – 32,767 |
| `i32` | 4 | -2,147,483,648 – 2,147,483,647 |
| `f16` | 2 | ±65,504, ~3 decimal digits |
| `f32` | 4 | IEEE 754 single |
| `f64` | 8 | IEEE 754 double |
| `bool` | 1 | Packed into bitfields inside structs. |

### Complex

| Type | Bytes | Description |
|:-----|------:|:------------|
| `string` | varint + N | Varint length prefix + raw bytes. |
| `vec2` | 8 | 2× f32. |
| `vec3` | 12 | 3× f32. |
| `cframe` | 24 | Position (3× f32) + axis-angle rotation (3× f32). |
| `color3` | 3 | RGB, 0–255 per channel, clamped. |
| `inst` | 2 | Instance reference via sidecar array. |
| `buff` | varint + N | Varint length prefix + raw bytes. |

### Composites

| Constructor | Description |
|:------------|:------------|
| `Lync.struct({ key = codec })` | Named fields. Bools auto-packed into bitfields. |
| `Lync.array(codec)` | Variable-length list. Varint count prefix. |
| `Lync.map(keyCodec, valueCodec)` | Key-value pairs. Varint count prefix. |
| `Lync.optional(codec)` | 1 byte presence flag + value if present. |
| `Lync.tuple(codec, codec, ...)` | Positional, ordered. No keys. |

### Delta

Reliable only. Errors at define time if combined with `unreliable = true`.

| Constructor | Description |
|:------------|:------------|
| `Lync.deltaStruct({ key = codec })` | First frame sends all fields. Subsequent frames send only dirty fields via bitmask. Unchanged frames cost 1 byte. |
| `Lync.deltaArray(codec)` | First frame sends all elements. Subsequent frames send only dirty elements via varint indices. Unchanged frames cost 1 byte. |

### Specialized

| Constructor | Description |
|:------------|:------------|
| `Lync.enum(value, value, ...)` | u8 index. Up to 256 variants. |
| `Lync.quantizedFloat(min, max, precision)` | Fixed-point. Auto-selects u8/u16/u32 based on range and precision. |
| `Lync.quantizedVec3(min, max, precision)` | 3× quantized float. |
| `Lync.bitfield({ key = spec })` | Sub-byte packing, 1–32 bits total. Spec: `{ type = "bool" }`, `{ type = "uint", width = N }`, or `{ type = "int", width = N }`. |
| `Lync.tagged(tagField, { name = codec })` | Discriminated union. u8 variant tag. Injects `tagField` into decoded table. |
| `Lync.nothing` | Zero bytes. Reads `nil`. |
| `Lync.unknown` | Bypasses serialization. Passed through Roblox's remote sidecar. |
| `Lync.auto` | Self-describing. Writes u8 type tag + value. Supports nil, bool, integers, f32, f64, string, vec2, vec3, color3, cframe, buffer. |

## Groups

Named player sets. Members auto-removed on `PlayerRemoving`.

| Function | Returns | Description |
|:---------|:--------|:------------|
| `Lync.createGroup(name)` | | Create a new group. Errors if exists. |
| `Lync.destroyGroup(name)` | | Remove group and all memberships. |
| `Lync.addToGroup(name, player)` | `boolean` | `true` if added, `false` if already in. |
| `Lync.removeFromGroup(name, player)` | `boolean` | `true` if removed, `false` if absent. |
| `Lync.hasInGroup(name, player)` | `boolean` | |
| `Lync.groupCount(name)` | `number` | |
| `Lync.getGroupSet(name)` | `{ [Player]: true }` | |
| `Lync.forEachInGroup(name, fn)` | | Calls `fn(player)` for each member. |

Send to a group via `Packet:sendToGroup(data, groupName)`.

## Middleware

Global packet intercept. Handlers chain in registration order. Return `nil` to drop.

| Function | Description |
|:---------|:------------|
| `Lync.onSend(fn(data, name, player) → data?)` | Intercept outgoing packets. Returns a remover function. |
| `Lync.onReceive(fn(data, name, player) → data?)` | Intercept incoming packets. Returns a remover function. |
| `Lync.onDrop(fn(player, reason, name, data))` | Called when a packet is rejected. Reason: `"nan"`, `"rate"`, `"validate"`, or custom string. |

## Benchmarks

1,000 packets/frame · 10 seconds · one player

| Scenario | Without Lync | With Lync | FPS |
|:---------|------------:|---------:|----:|
| Static booleans (1B) | 480 Kbps | **2.25 Kbps** | 59.99 |
| Static entities (34B) | 16,320 Kbps | **2.51 Kbps** | 60.00 |
| Moving entities | 16,320 Kbps | **3.31 Kbps** | 59.99 |
| Chaotic entities | 16,320 Kbps | **4.66 Kbps** | 60.01 |

## Limits & Configuration

Call configuration functions before `Lync.start()`.

| Constraint | Default | Configure | Notes |
|:-----------|--------:|:----------|:------|
| Packet types | 255 | — | u8 on the wire. Each query uses 2 IDs. |
| Buffer / channel / frame | 256 KB | `Lync.setChannelMaxSize(n)` | Range: 4 KB – 1 MB. |
| Concurrent queries | 65,536 | — | u16 correlation IDs. Freed on response or timeout. |
| NaN/inf scan depth | 16 | `Lync.setValidationDepth(n)` | Range: 4 – 32. |
| Channel pool | 16 | `Lync.setPoolSize(n)` | Range: 2 – 128. Excess is GC'd. |
| Namespaces | 64 | — | |
| Delta + unreliable | — | — | Errors at define time if combined. |

## License

MIT
