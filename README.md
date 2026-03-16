<h1 align="center">Lync</h1>
<p align="center">Buffer networking for Roblox. Delta compression, XOR framing, built-in security.</p>
<p align="center">
  <a href="https://github.com/Axp3cter/Lync/releases/latest">Releases</a> ·
  <a href="#benchmarks">Benchmarks</a> ·
  <a href="#limits--configuration">Limits</a>
</p>

## Install

```toml
[dependencies]
Lync = "axpecter/lync@0.8.0"
```

Or grab the `.rbxm` from [releases](https://github.com/Axp3cter/Lync/releases/latest) and drop it in `ReplicatedStorage`.

> [!IMPORTANT]
> Define everything before calling `Lync.start()`. Packets, queries, namespaces, all of it.

## Lifecycle

| Function | What it does |
|:---------|:------------|
| `Lync.start()` | Sets up transport. Server creates remotes, client connects. Call once after all your definitions. |
| `Lync.version` | `"0.8.0"` |

## Packets

`Lync.definePacket(name, config)` returns a Packet.

| Config | Type | Required | What it does |
|:-------|:-----|:--------:|:-------------|
| `value` | Codec | Yes | How to serialize the payload. |
| `unreliable` | boolean | No | Sends over UnreliableRemoteEvent. Default `false`. Cant use with delta codecs. |
| `rateLimit` | `{ maxPerSecond, burstAllowance? }` | No | Server-side token bucket. Burst defaults to maxPerSecond if you dont set it. |
| `validate` | `(data, player) → (bool, string?)` | No | Server-side. Return `false, "reason"` to drop. Runs after NaN scan. |

**Server methods:**

| Method | What it does |
|:-------|:------------|
| `sendTo(data, player)` | Send to one player. |
| `sendToAll(data)` | Send to everyone. |
| `sendToAllExcept(data, except)` | Send to everyone except one. |
| `sendToList(data, players)` | Send to a list. |
| `sendToGroup(data, groupName)` | Send to a named group. |

**Client methods:**

| Method | What it does |
|:-------|:------------|
| `send(data)` | Send to server. |

**Shared methods:**

| Method | What it does |
|:-------|:------------|
| `listen(fn(data, sender))` | Listen for incoming. Returns a Connection. Sender is `Player` on server, `nil` on client. |
| `once(fn(data, sender))` | Same as listen but auto-disconnects after one fire. |
| `wait()` | Yields until next fire. Returns `(data, sender)`. |
| `disconnectAll()` | Kills all listeners on this packet. |

## Queries

`Lync.defineQuery(name, config)` returns a Query. Basically RemoteFunctions but built on RemoteEvents. Returns `nil` if the other side times out or errors.

| Config | Type | Required | What it does |
|:-------|:-----|:--------:|:-------------|
| `request` | Codec | Yes | How to serialize the request. |
| `response` | Codec | Yes | How to serialize the response. |
| `timeout` | number | No | Seconds before giving up. Default `5`. |
| `rateLimit` | `{ maxPerSecond, burstAllowance? }` | No | Server-side token bucket on incoming requests. |
| `validate` | `(data, player) → (bool, string?)` | No | Server-side validation on incoming requests. |

| Method | Where | What it does |
|:-------|:------|:-------------|
| `listen(fn)` | Both | Register a handler. Server gets `fn(request, player) → response`. Client gets `fn(request) → response`. |
| `invoke(request)` | Client | Send request to server, yield until response comes back or timeout. |
| `invoke(request, player)` | Server | Send request to a specific client, yield until response or timeout. |
| `invokeAll(request)` | Server | Send request to all players, yield until all respond or timeout. Returns `{ [Player]: response? }`. |
| `invokeList(request, players)` | Server | Send request to a list of players, yield until all respond or timeout. Returns `{ [Player]: response? }`. |
| `invokeGroup(request, groupName)` | Server | Send request to all players in a named group. Returns `{ [Player]: response? }`. |
| `Lync.queryPendingCount()` | Both | How many queries are currently waiting for a response. |

## Namespaces

`Lync.defineNamespace(name, config)` returns a Namespace. Takes a `packets` table and/or a `queries` table. All names get auto-prefixed with `"YourNamespace."` so nothing collides.

You access packets and queries by their short name directly on the returned object.

| Method | What it does |
|:-------|:------------|
| `ns.PacketName` | The packet, by short name. |
| `ns.QueryName` | The query, by short name. |
| `ns:listenAll(fn(name, data, sender))` | Listens to every packet in the namespace. `name` is the short name without prefix. Returns a Connection. |
| `ns:onSend(fn(data, name, player) → data?)` | Send middleware that only runs for this namespace. Returns a remover. |
| `ns:onReceive(fn(data, name, player) → data?)` | Receive middleware that only runs for this namespace. Returns a remover. |
| `ns:disconnectAll()` | Kills all listeners made through `listenAll`. |
| `ns:destroy()` | Kills listeners and removes scoped middleware. Full cleanup. |
| `ns:packetNames()` | Sorted list of packet short names. |
| `ns:queryNames()` | Sorted list of query short names. |

## Types

### Primitives

| Type | Bytes | Range |
|:-----|------:|:------|
| `u8` | 1 | 0 to 255 |
| `u16` | 2 | 0 to 65,535 |
| `u32` | 4 | 0 to 4,294,967,295 |
| `i8` | 1 | -128 to 127 |
| `i16` | 2 | -32,768 to 32,767 |
| `i32` | 4 | -2,147,483,648 to 2,147,483,647 |
| `f16` | 2 | ±65,504, roughly 3 digits of precision |
| `f32` | 4 | IEEE 754 single |
| `f64` | 8 | IEEE 754 double |
| `bool` | 1 | Gets packed into bitfields when inside structs. |

### Complex

| Type | Bytes | What it is |
|:-----|------:|:-----------|
| `string` | varint + N | Varint length prefix then raw bytes. |
| `vec2` | 8 | 2x f32. |
| `vec3` | 12 | 3x f32. |
| `cframe` | 24 | Position as 3x f32, rotation as axis-angle 3x f32. |
| `color3` | 3 | RGB 0-255 per channel, clamped. |
| `inst` | 2 | Instance ref through sidecar array. |
| `buff` | varint + N | Varint length prefix then raw bytes. |

### Composites

| Constructor | What it does |
|:------------|:------------|
| `Lync.struct({ key = codec })` | Named fields. Bools get packed into bitfields automatically. |
| `Lync.array(codec)` | Variable length list with varint count. |
| `Lync.map(keyCodec, valueCodec)` | Key-value pairs with varint count. |
| `Lync.optional(codec)` | 1 byte flag, value only if present. |
| `Lync.tuple(codec, codec, ...)` | Ordered positional values, no keys. |

### Delta

Reliable only. Lync will error if you try to use these with `unreliable = true`.

| Constructor | What it does |
|:------------|:------------|
| `Lync.deltaStruct({ key = codec })` | First frame sends everything. After that only dirty fields get sent via bitmask. If nothing changed it costs 1 byte. |
| `Lync.deltaArray(codec)` | Same idea but for arrays. Dirty elements get sent with varint indices. |
| `Lync.deltaMap(keyCodec, valueCodec)` | Delta compression for key-value maps. Sends only upserted and removed entries after the first frame. |

### Specialized

| Constructor | What it does |
|:------------|:------------|
| `Lync.enum(value, value, ...)` | u8 index, up to 256 variants. |
| `Lync.quantizedFloat(min, max, precision)` | Fixed-point compression. Picks u8/u16/u32 based on your range and precision. |
| `Lync.quantizedVec3(min, max, precision)` | Same thing but for all 3 components. |
| `Lync.bitfield({ key = spec })` | Sub-byte packing, 1 to 32 bits total. Spec is `{ type = "bool" }` or `{ type = "uint", width = N }` or `{ type = "int", width = N }`. |
| `Lync.tagged(tagField, { name = codec })` | Discriminated union with a u8 variant tag. Puts `tagField` into the decoded table so you know which variant it is. |
| `Lync.nothing` | Zero bytes. Reads nil. Good for fire-and-forget signals. |
| `Lync.unknown` | Skips serialization entirely, goes through Roblox's sidecar. Use when you dont have a codec for the value. |
| `Lync.auto` | Self-describing. Writes a u8 type tag then the value. Handles nil, bool, all number types, string, vec2, vec3, color3, cframe, buffer. |

## Groups

Named player sets. Members get removed automatically on `PlayerRemoving`.

| Function | Returns | What it does |
|:---------|:--------|:-------------|
| `Lync.createGroup(name)` | | Makes a new group. Errors if it already exists. |
| `Lync.destroyGroup(name)` | | Removes the group and all memberships. |
| `Lync.addToGroup(name, player)` | `boolean` | `true` if added, `false` if already in. |
| `Lync.removeFromGroup(name, player)` | `boolean` | `true` if removed, `false` if wasnt in there. |
| `Lync.hasInGroup(name, player)` | `boolean` | |
| `Lync.groupCount(name)` | `number` | |
| `Lync.getGroupSet(name)` | `{ [Player]: true }` | |
| `Lync.forEachInGroup(name, fn)` | | Calls `fn(player)` for each member. |

Send to a group with `Packet:sendToGroup(data, groupName)`.

## Middleware

Global intercept on all packets. Handlers run in the order you registered them. Return `nil` from a handler to drop the packet.

| Function | What it does |
|:---------|:------------|
| `Lync.onSend(fn(data, name, player) → data?)` | Runs before a packet goes out. Returns a remover function. |
| `Lync.onReceive(fn(data, name, player) → data?)` | Runs when a packet comes in. Returns a remover function. |
| `Lync.onDrop(fn(player, reason, name, data))` | Fires when a packet gets rejected. Reason is `"nan"`, `"rate"`, `"validate"`, or whatever string your validate function returned. |

## Benchmarks

### Lync Tests

1,000 packets/frame, 10 seconds, one player.

| Scenario | Without Lync | With Lync | FPS |
|:---------|------------:|---------:|----:|
| Static booleans (1B) | 480 Kbps | **2.24 Kbps** | 59.99 |
| Static entities (34B) | 16,320 Kbps | **2.50 Kbps** | 60.00 |
| Moving entities | 16,320 Kbps | **3.35 Kbps** | 59.99 |
| Chaotic entities | 16,320 Kbps | **4.63 Kbps** | 59.99 |

### Cross-Library Comparison

Same data shapes and methodology as [Blink's benchmark suite](https://github.com/1Axen/blink/blob/main/benchmark/Benchmarks.md). 1,000 fires/frame, 10 seconds, same data every frame. Kbps scaled by 60/FPS.

**Entities** (100x struct of 6x u8, fired 1000 times/frame)

| Tool (FPS) | Median | P0 | P80 | P90 | P95 | P100 |
|:-----------|-------:|---:|----:|----:|----:|-----:|
| roblox | 16.00 | 16.00 | 15.00 | 15.00 | 15.00 | 15.00 |
| blink | 42.00 | 45.00 | 42.00 | 42.00 | 42.00 | 42.00 |
| zap | 39.00 | 40.00 | 38.00 | 38.00 | 38.00 | 38.00 |
| bytenet | 32.00 | 34.00 | 32.00 | 32.00 | 32.00 | 31.00 |
| **lync** | 29.00 | 30.00 | 29.00 | 29.00 | 29.00 | 29.00 |

| Tool (Kbps) | Median | P0 | P80 | P90 | P95 | P100 |
|:------------|-------:|---:|----:|----:|----:|-----:|
| roblox | 559,364 | 559,364 | 676,715 | 676,715 | 676,715 | 784,081 |
| blink | 41.81 | 26.30 | 42.40 | 42.48 | 42.48 | 42.62 |
| zap | 41.71 | 25.46 | 42.19 | 42.32 | 42.32 | 42.93 |
| bytenet | 41.64 | 22.84 | 42.36 | 42.82 | 42.82 | 43.24 |
| **lync** | 3.96 | 3.81 | 4.18 | 5.45 | 5.45 | 10.40 |

**Booleans** (1000x bool, fired 1000 times/frame)

| Tool (FPS) | Median | P0 | P80 | P90 | P95 | P100 |
|:-----------|-------:|---:|----:|----:|----:|-----:|
| roblox | 21.00 | 22.00 | 20.00 | 19.00 | 19.00 | 19.00 |
| blink | 97.00 | 98.00 | 97.00 | 96.00 | 96.00 | 96.00 |
| zap | 52.00 | 53.00 | 51.00 | 51.00 | 51.00 | 49.00 |
| bytenet | 35.00 | 37.00 | 35.00 | 35.00 | 35.00 | 34.00 |
| **lync** | 23.00 | 24.00 | 22.00 | 22.00 | 22.00 | 22.00 |

| Tool (Kbps) | Median | P0 | P80 | P90 | P95 | P100 |
|:------------|-------:|---:|----:|----:|----:|-----:|
| roblox | 353,107 | 196,826 | 690,747 | 842,240 | 842,240 | 1,124,176 |
| blink | 7.91 | 7.41 | 7.93 | 7.99 | 7.99 | 8.00 |
| zap | 8.10 | 5.75 | 8.17 | 8.22 | 8.22 | 8.27 |
| bytenet | 8.11 | 5.07 | 8.35 | 8.46 | 8.46 | 8.47 |
| **lync** | 4.90 | 4.67 | 5.04 | 5.25 | 5.25 | 5.66 |

> [!NOTE]
> Other tool numbers are from [Blink's published benchmarks](https://github.com/1Axen/blink/blob/main/benchmark/Benchmarks.md) (v0.17.1, Ryzen 9 7900X, 34GB DDR5-4800). Lync was run on different hardware so FPS numbers arent directly comparable but bandwidth numbers are since Kbps is scaled by 60/FPS.

## Limits & Configuration

Call these before `Lync.start()`.

| What | Default | How to change | Notes |
|:-----|--------:|:--------------|:------|
| Packet types | 255 | Cant change | u8 on the wire. Each query eats 2 IDs. |
| Buffer per channel per frame | 256 KB | `Lync.setChannelMaxSize(n)` | 4 KB to 1 MB. |
| Concurrent queries | 65,536 | Cant change | u16 correlation IDs. Freed on response or timeout. |
| NaN/inf scan depth | 16 | `Lync.setValidationDepth(n)` | 4 to 32. |
| Channel pool | 16 | `Lync.setPoolSize(n)` | 2 to 128. Extra gets GCd. |
| Namespaces | 64 | Cant change | |
| Delta + unreliable | Nope | Cant change | Errors at define time. |

## License

MIT